import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';
import 'package:moor_ffi/database.dart' as ffi;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/extension.dart';
import 'package:synchronized/synchronized.dart';

import 'import.dart';

final _debug = false; // devWarning(true);

/// By id
var ffiDbs = <int, SqfliteFfiDatabase>{};

/// By path
var ffiSingleInstanceDbs = <String, SqfliteFfiDatabase>{};

var _lastFfiId = 0;

class SqfliteFfiException implements DatabaseException {
  final String message;
  Map<String, dynamic> details;

  SqfliteFfiException({@required this.message, @required this.details});

  @override
  bool isDatabaseClosedError() {
    // TODO: implement isDatabaseClosedError
    return null;
  }

  @override
  bool isNoSuchTableError([String table]) {
    // TODO: implement isNoSuchTableError
    return null;
  }

  @override
  bool isOpenFailedError() {
    // TODO: implement isOpenFailedError
    return null;
  }

  @override
  bool isReadOnlyError() {
    // TODO: implement isReadOnlyError
    return null;
  }

  @override
  bool isSyntaxError() {
    // TODO: implement isSyntaxError
    return null;
  }

  @override
  bool isUniqueConstraintError([String field]) {
    // TODO: implement isUniqueConstraintError
    return null;
  }

  @override
  String toString() {
    var map = <String, dynamic>{};
    if (details != null) {
      map['details'] = details;
    }
    return '${super.toString()} $map';
  }
}

class SqfliteFfiOperation {
  String method;
  String sql;
  List sqlArguments;
}

class SqfliteFfiDatabase {
  final int id;
  final bool singleInstance;
  final String path;
  final bool readOnly;
  final ffi.Database ffiDb;

  SqfliteFfiDatabase(this.id, this.ffiDb,
      {@required this.singleInstance,
      @required this.path,
      @required this.readOnly}) {
    ffiDbs[id] = this;
  }

  Map<String, dynamic> toDebugMap() {
    var map = <String, dynamic>{
      'path': path,
      'id': id,
      'readOnly': readOnly,
      'singleInstance': singleInstance
    };
    return map;
  }

  @override
  String toString() => toDebugMap().toString();
}

class SqfliteFfiHandler {
  final multiInstanceLocks = <String, Lock>{};
  final mainLock = Lock();
}

final sqfliteFfiHandler = SqfliteFfiHandler();

class _MultiInstanceLocker {
  final String path;

  _MultiInstanceLocker(this.path);

  @override
  int get hashCode => path?.hashCode ?? 0;

  @override
  bool operator ==(other) {
    if (other is _MultiInstanceLocker) {
      return other.path == path;
    }
    return false;
  }
}

/// Extension on MethodCall
extension SqfliteFfiMethodCallHandler on MethodCall {
  Future<T> synchronized<T>(Future<T> Function() action) async {
    var path = getPath() ?? getDatabase()?.path;
    return await (_MultiInstanceLocker(path).synchronized(action));
  }

  /// Handle a method call
  Future<dynamic> handle() async {
    Future doHandle() async {
      // devPrint('$this');
      try {
        var result = await _handle();

        // devPrint('result: $result');
        return result;
      } catch (e, st) {
        if (e is ffi.SqliteException) {
          var database = getDatabase();
          var sql = getSql();
          var sqlArguments = getSqlArguments();
          var wrapped = wrapSqlException(e, details: <String, dynamic>{
            'database': database.toDebugMap(),
            'sql': sql,
            'arguments': sqlArguments
          });
          // devPrint(wrapped);
          throw wrapped;
        }
        if (e is PlatformException) {
          // devPrint('throwing $e');
          var database = getDatabase();
          var sql = getSql();
          var sqlArguments = getSqlArguments();
          if (_debug) {
            print('$e in ${database?.toDebugMap()}');
          }
          throw PlatformException(
              code: e.code,
              message: e.message,
              details: <String, dynamic>{
                'database': database?.toDebugMap(),
                'sql': sql,
                'arguments': sqlArguments,
                'details': e.details,
              });
        } else {
          if (_debug) {
            print('handleError: $e');
            print('stackTrace : $st');
          }
          throw PlatformException(
              code: 'sqflite_ffi_test_error', message: e.toString());
        }
      }
    }

    try {
      return await synchronized(doHandle);
    } catch (e, st) {
      if (_debug) {
        print(st);
      }
      rethrow;
    }
  }

  /// Handle a method call
  Future<dynamic> _handle() async {
    switch (method) {
      case 'openDatabase':
        return await handleOpenDatabase();
      case 'closeDatabase':
        return await handleCloseDatabase();

      case 'query':
        return await handleQuery();
      case 'execute':
        return await handleExecute();
      case 'insert':
        return await handleInsert();
      case 'update':
        return await handleUpdate();
      case 'batch':
        return await handleBatch();

      case 'getDatabasesPath':
        return await handleGetDatabasesPath();
      case 'deleteDatabase':
        return await handleDeleteDatabase();
      default:
        throw ArgumentError('Invalid method $method $this');
    }
  }

  String getDatabasesPath() {
    return absolute(join('.dart_tool', 'sqflite_ffi_test', 'databases'));
  }

  Future handleOpenDatabase() async {
    //dePrint(arguments);
    var path = arguments['path'];

    //devPrint('opening $path');
    var singleInstance = (arguments['singleInstance'] as bool) ?? false;
    var readOnly = (arguments['readOnly'] as bool) ?? false;
    if (singleInstance) {
      var database = ffiSingleInstanceDbs[path];
      if (database != null) {
        return database;
      }
    }
    ffi.Database ffiDb;
    try {
      if (path == inMemoryDatabasePath) {
        ffiDb = ffi.Database.memory();
      } else {
        if (readOnly) {
          if (!(await File(path).exists())) {
            throw StateError('file $path not found');
          }
        } else {
          if (!(await File(path).exists())) {
            // Make sure its parent exists
            try {
              await Directory(dirname(path)).create(recursive: true);
            } catch (_) {}
          }
        }
        ffiDb = ffi.Database.open(path);
      }
    } on ffi.SqliteException catch (e) {
      throw wrapSqlException(e, code: 'open_failed');
    }

    var id = ++_lastFfiId;
    var database = SqfliteFfiDatabase(id, ffiDb,
        singleInstance: singleInstance, path: path, readOnly: readOnly);
    if (singleInstance) {
      ffiSingleInstanceDbs[path] = database;
    }
    //devPrint('opened: $database');

    return <String, dynamic>{'id': id};
  }

  Future handleCloseDatabase() async {
    var database = getDatabaseOrThrow();
    if (database.singleInstance ?? false) {
      ffiSingleInstanceDbs.remove(database.path);
    }
    database.ffiDb.close();
  }

  SqfliteFfiDatabase getDatabaseOrThrow() {
    var database = getDatabase();
    if (database == null) {
      throw StateError('Database ${getDatabaseId()} not found');
    }
    return database;
  }

  SqfliteFfiDatabase getDatabase() {
    var id = getDatabaseId();
    var database = ffiDbs[id];
    return database;
  }

  int getDatabaseId() {
    if (arguments != null) {
      return arguments['id'] as int;
    }
    return null;
  }

  String getSql() {
    var sql = arguments['sql'] as String;
    return sql;
  }

  bool isInMemory(String path) {
    return path == inMemoryDatabasePath;
  }

  // Return the path argument if any
  String getPath() {
    var arguments = this.arguments;
    if (arguments != null) {
      var path = arguments['path'] as String;
      if ((path != null) && !isInMemory(path) && isRelative(path)) {
        path = join(getDatabasesPath(), path);
      }
      return path;
    }
    return null;
  }

  /// Check the arguments
  List getSqlArguments() {
    var arguments = this.arguments;
    if (arguments != null) {
      var sqlArguments = arguments['arguments'] as List;
      if (sqlArguments != null) {
        // Check the argument, make it stricter
        for (var argument in sqlArguments) {
          if (argument == null) {
          } else if (argument is num) {
          } else if (argument is String) {
          } else if (argument is Uint8List) {
          } else {
            throw ArgumentError(
                'Invalid sql argument type \'${argument.runtimeType}\': $argument');
          }
        }
      }
      return sqlArguments;
    }
    return null;
  }

  bool getNoResult() {
    var noResult = arguments['noResult'] as bool;
    return noResult;
  }

  List<SqfliteFfiOperation> getOperations() {
    var operations = <SqfliteFfiOperation>[];
    arguments['operations'].cast<Map>().forEach((operationArgument) {
      operations.add(SqfliteFfiOperation()
        ..sql = operationArgument['sql'] as String
        ..sqlArguments = operationArgument['arguments'] as List
        ..method = operationArgument['method'] as String);
    });
    return operations;
  }

  Map<String, dynamic> packResult(ffi.Result result) {
    var columns = result.columnNames;
    var rows = result.rows;
    // This is what sqflite expected
    return <String, dynamic>{'columns': columns, 'rows': rows};
  }

  Future handleQuery() async {
    var database = getDatabaseOrThrow();
    var sql = getSql();
    var sqlArguments = getSqlArguments();
    return _handleQuery(database, sqlArguments: sqlArguments, sql: sql);
  }

  static const sqliteErrorCode = 'sqlite_error';

  PlatformException wrapSqlException(ffi.SqliteException e,
      {String code, Map<String, dynamic> details}) {
    return PlatformException(
        // Hardcoded
        code: sqliteErrorCode,
        message: code == null ? '$e' : '$code: $e',
        details: details);
  }

  Future handleExecute() async {
    var database = getDatabaseOrThrow();
    var sql = getSql();
    var sqlArguments = getSqlArguments();

    var writeAttempt = false;
    // Handle some cases
    // PRAGMA user_version =
    if ((sql?.toLowerCase()?.trim()?.startsWith('pragma user_version =')) ??
        false) {
      writeAttempt = true;
    }
    if (writeAttempt && (database.readOnly ?? false)) {
      throw PlatformException(
          code: sqliteErrorCode, message: 'Database readonly');
    }
    return _handleExecute(database, sql: sql, sqlArguments: sqlArguments);
  }

  Future _handleExecute(SqfliteFfiDatabase database,
      {String sql, List sqlArguments}) async {
    //database.ffiDb.execute(sql);
    if (sqlArguments?.isNotEmpty ?? false) {
      var preparedStatement = database.ffiDb.prepare(sql);
      try {
        preparedStatement.execute(sqlArguments);
        return null;
      } finally {
        preparedStatement.close();
      }
    } else {
      database.ffiDb.execute(sql);
    }
  }

  Future _handleQuery(SqfliteFfiDatabase database,
      {String sql, List sqlArguments}) async {
    var preparedStatement = database.ffiDb.prepare(sql);

    try {
      var result = preparedStatement.select(sqlArguments);
      return packResult(result);
    } finally {
      preparedStatement.close();
    }
  }

  Future handleInsert() async {
    var database = getDatabaseOrThrow();
    if (database.readOnly ?? false) {
      throw PlatformException(
          code: sqliteErrorCode, message: 'Database readonly');
    }

    await handleExecute();

    var id = database.ffiDb.getLastInsertId();
    return id;
  }

  Future handleUpdate() async {
    var database = getDatabaseOrThrow();
    if (database.readOnly ?? false) {
      throw PlatformException(
          code: sqliteErrorCode, message: 'Database readonly');
    }

    await handleExecute();

    var id = database.ffiDb.getUpdatedRows();
    return id;
  }

  Future handleBatch() async {
    //devPrint(arguments);
    var database = getDatabaseOrThrow();
    var operations = getOperations();
    List<Map<String, dynamic>> results;
    var noResult = getNoResult() ?? false;
    if (!noResult) {
      results = <Map<String, dynamic>>[];
    }
    for (var operation in operations) {
      switch (operation.method) {
        case 'insert':
          {
            await _handleExecute(database,
                sql: operation.sql, sqlArguments: operation.sqlArguments);
            if (!noResult) {
              results.add(<String, dynamic>{
                'result': database.ffiDb.getLastInsertId()
              });
            }
            break;
          }
        case 'execute':
          {
            await _handleExecute(database,
                sql: operation.sql, sqlArguments: operation.sqlArguments);
            if (!noResult) {
              results.add(<String, dynamic>{'result': null});
            }
            break;
          }
        case 'query':
          {
            var result = await _handleQuery(database,
                sql: operation.sql, sqlArguments: operation.sqlArguments);
            if (!noResult) {
              results.add(<String, dynamic>{'result': result});
            }
            break;
          }
        case 'update':
          {
            await _handleExecute(database,
                sql: operation.sql, sqlArguments: operation.sqlArguments);
            if (!noResult) {
              results.add(
                  <String, dynamic>{'result': database.ffiDb.getUpdatedRows()});
            }
            break;
          }
        default:
          throw 'batch operation ${operation.method} not supported';
      }
    }
    return results;
  }

  Future handleGetDatabasesPath() async {
    return getDatabasesPath();
  }

  Future handleDeleteDatabase() async {
    var path = getPath();
    //TODO handle single instance database
    //devPrint('deleting $path');

    var singleInstanceDatabase = ffiSingleInstanceDbs[path];
    if (singleInstanceDatabase != null) {
      singleInstanceDatabase.ffiDb.close();
      ffiSingleInstanceDbs.remove(path);
    }

    // Ignore failure
    try {
      await File(path).delete();
    } catch (_) {}
  }
}

// final sqfliteFfiMethodCallHandler = SqfliteFfiMethodCallHandler();
