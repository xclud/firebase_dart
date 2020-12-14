import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:firebase_dart/src/database/impl/operations/tree.dart';
import 'package:firebase_dart/src/database/impl/persistence/prune_forest.dart';
import 'package:firebase_dart/src/database/impl/persistence/tracked_query.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';

import '../data_observer.dart';
import '../tree.dart';
import '../utils.dart';
import '../treestructureddata.dart';
import 'engine.dart';

final _logger = Logger('firebase.persistence');

class HivePersistenceStorageEngine extends PersistenceStorageEngine {
  static const _serverCachePrefix = 'C';
  static const _trackedQueryPrefix = 'Q';
  static const _userWritesPrefix = 'W';

  IncompleteData _serverCache = IncompleteData.empty();

  final KeyValueDatabase database;

  HivePersistenceStorageEngine(this.database);

  @override
  void beginTransaction() {
    database.beginTransaction();
  }

  @override
  void deleteTrackedQuery(int trackedQueryId) {
    database.delete('$_trackedQueryPrefix:$trackedQueryId');
  }

  @override
  void endTransaction() {
    database.endTransaction();
  }

  @override
  List<TrackedQuery> loadTrackedQueries() {
    return [
      ...database
          .valuesBetween(
              startKey: '$_trackedQueryPrefix:',
              endKey: '$_trackedQueryPrefix;')
          .map((v) => TrackedQuery.fromJson(v))
    ];
  }

  @override
  void overwriteServerCache(TreeOperation operation) {
    var newValue = _serverCache.applyOperation(operation);

    newValue.forEachCompleteNode((k, v) {
      database.deleteAll(database.keysBetween(
        startKey: '$_serverCachePrefix:$k/',
        endKey: '$_serverCachePrefix:${k}0',
      ));
      database.put('$_serverCachePrefix:$k/', v.toJson(true));
    });
    _serverCache = newValue;
  }

  @override
  void pruneCache(Path<Name> prunePath, PruneForest pruneForest) {
    database._verifyInsideTransaction();

    _serverCache.forEachCompleteNode((absoluteDataPath, value) {
      assert(
          prunePath == absoluteDataPath ||
              !absoluteDataPath.contains(prunePath),
          'Pruning at $prunePath but we found data higher up.');
      if (prunePath.contains(absoluteDataPath)) {
        final dataPath = absoluteDataPath.skip(prunePath.length);
        final dataNode = value;
        if (pruneForest.shouldPruneUnkeptDescendants(dataPath)) {
          var newCache = pruneForest
              .child(dataPath)
              .foldKeptNodes<IncompleteData>(IncompleteData.empty(),
                  (keepPath, value, accum) {
            var op = TreeOperation.overwrite(
                Path.from([...absoluteDataPath, ...keepPath]),
                dataNode.getChild(keepPath));
            return accum.applyOperation(op);
          });
          _serverCache = _serverCache
              .removeWrite(absoluteDataPath)
              .applyOperation(newCache.toOperation());

          database.deleteAll(database.keysBetween(
            startKey: '$_serverCachePrefix:$absoluteDataPath/',
            endKey: '$_serverCachePrefix:${absoluteDataPath}0',
          ));
          _serverCache.forEachCompleteNode((k, v) {
            database.put('$_serverCachePrefix:$k/', v.toJson(true));
          }, absoluteDataPath);
        } else {
          // NOTE: This is technically a valid scenario (e.g. you ask to prune at / but only want to
          // prune 'foo' and 'bar' and ignore everything else).  But currently our pruning will
          // explicitly prune or keep everything we know about, so if we hit this it means our
          // tracked queries and the server cache are out of sync.
          assert(pruneForest.shouldKeep(dataPath),
              'We have data at $dataPath that is neither pruned nor kept.');
        }
      }
    });
  }

  @override
  void removeUserOperation(int writeId) {
    database.delete('$_userWritesPrefix:$writeId');
  }

  @override
  void resetPreviouslyActiveTrackedQueries(DateTime lastUse) {
    for (var query in loadTrackedQueries()) {
      if (query.active) {
        query = query.setActiveState(false).updateLastUse(lastUse);
        saveTrackedQuery(query);
      }
    }
  }

  @override
  void saveTrackedQuery(TrackedQuery trackedQuery) {
    database.put(
        '$_trackedQueryPrefix:${trackedQuery.id}', trackedQuery.toJson());
  }

  @override
  void saveUserOperation(TreeOperation operation, int writeId) {
    var o = operation.nodeOperation;
    var json = {
      'p': operation.path.join('/'),
      if (o is Overwrite) 's': o.value.toJson(true),
      if (o is Merge)
        'm': {
          for (var c in o.overwrites)
            c.path.join('/'): (c as Overwrite).value.toJson(true)
        }
    };
    database.put('$_userWritesPrefix:$writeId', json);
  }

  @override
  IncompleteData serverCache(Path<Name> path) {
    return _serverCache.child(path);
  }

  @override
  int serverCacheEstimatedSizeInBytes() {
    return _serverCache.estimatedStorageSize;
  }

  @override
  void setTransactionSuccessful() {}
}

class KeyValueDatabase {
  final Box box;

  DateTime _transactionStart;

  Map<String, dynamic> _transaction;

  KeyValueDatabase(this.box);

  bool get isInsideTransaction => _transaction != null;

  Iterable<dynamic> valuesBetween({String startKey, String endKey}) {
    // TODO merge transaction data
    return box.valuesBetween(startKey: startKey, endKey: endKey);
  }

  Iterable<String> keysBetween({String startKey, String endKey}) sync* {
    // TODO merge transaction data
    for (var k in box.keys) {
      if (Comparable.compare(k, startKey) < 0) continue;
      if (Comparable.compare(k, endKey) > 0) return;
      yield k;
    }
  }

  bool containsKey(String key) {
    return box.containsKey(key);
  }

  void beginTransaction() {
    assert(!isInsideTransaction,
        'runInTransaction called when an existing transaction is already in progress.');
    _logger.fine('Starting transaction.');
    _transactionStart = clock.now();
    _transaction = {};
  }

  void endTransaction() {
    assert(isInsideTransaction);
    box.putAll(_transaction);
    box.deleteAll(_transaction.keys.where((k) => _transaction[k] == null));
    _transaction = null;
    var elapsed = clock.now().difference(_transactionStart);
    _logger.fine('Transaction completed. Elapsed: $elapsed');
    _transactionStart = null;
  }

  void close() {
    box.close();
  }

  void delete(String key) {
    _verifyInsideTransaction();
    _transaction[key] = null;
  }

  void deleteAll(Iterable<String> keys) {
    _verifyInsideTransaction();
    for (var k in keys) {
      _transaction[k] = null;
    }
  }

  void put(String key, dynamic value) {
    _verifyInsideTransaction();
    _transaction[key] = value;
  }

  void _verifyInsideTransaction() {
    assert(
        isInsideTransaction, 'Transaction expected to already be in progress.');
  }
}

extension IncompleteDataX on IncompleteData {
  int get estimatedStorageSize {
    var bytes = 0;
    forEachCompleteNode((k, v) {
      bytes +=
          k.join('/').length + json.encode(v.toJson(true)).toString().length;
    });
    return bytes;
  }
}
