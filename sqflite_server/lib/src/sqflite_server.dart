import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:path/path.dart' as path;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart' as sqflite_plugin;
import 'package:sqflite/sqlite_api.dart';
import 'package:sqflite_server/sqflite_context.dart';
import 'package:sqflite_server/src/constant.dart';
import 'package:sqflite_server/src/sqflite_import.dart';
import 'package:tekartik_common_utils/common_utils_import.dart' hide devPrint;
import 'package:tekartik_web_socket/web_socket.dart';
import 'package:tekartik_web_socket_io/web_socket_io.dart';

typedef SqfliteServerNotifyCallback = void Function(
    bool response, String method, dynamic params);

/// Web socket server
class SqfliteServer {
  final DatabaseFactory factory;

  SqfliteInvokeHandler get invokeHandler => factory as SqfliteInvokeHandler;

  SqfliteServer._(
      this._webSocketChannelServer, this._notifyCallback, this.factory) {
    _webSocketChannelServer.stream.listen((WebSocketChannel<String> channel) {
      _channels.add(SqfliteServerChannel(this, channel));
    });
  }

  SqfliteContext _sqfliteLocalContext;

  SqfliteContext get sqfliteLocalContext =>
      _sqfliteLocalContext ??= SqfliteLocalContext(databaseFactory: factory);

  final SqfliteServerNotifyCallback _notifyCallback;
  final List<SqfliteServerChannel> _channels = [];
  final WebSocketChannelServer<String> _webSocketChannelServer;

  static Future<SqfliteServer> serve(
      {WebSocketChannelServerFactory webSocketChannelServerFactory,
      dynamic address,
      int port,
      SqfliteServerNotifyCallback notifyCallback,
      DatabaseFactory factory}) async {
    factory ??= sqflite_plugin.databaseFactory;
    webSocketChannelServerFactory ??= webSocketChannelServerFactoryIo;
    var webSocketChannelServer = await webSocketChannelServerFactory
        .serve<String>(address: address, port: port);
    if (webSocketChannelServer != null) {
      return SqfliteServer._(webSocketChannelServer, notifyCallback, factory);
    }
    return null;
  }

  Future close() => _webSocketChannelServer.close();

  String get url => _webSocketChannelServer.url;

  int get port => _webSocketChannelServer.port;
}

/// We have one channer per client
class SqfliteServerChannel {
  // Keep
  final _openDatabaseIds = <int>[];

  SqfliteServerChannel(this._sqfliteServer, WebSocketChannel<String> channel)
      : _rpcServer = json_rpc.Server(channel) {
    // Specific method for getting server info upon start
    _rpcServer.registerMethod(methodGetServerInfo,
        (json_rpc.Parameters parameters) {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodGetServerInfo, parameters.value);
      }
      var result = <String, dynamic>{
        keyName: serverInfoName,
        keyVersion: serverInfoVersion.toString(),
        keySupportsWithoutRowId:
            _sqfliteServer.sqfliteLocalContext.supportsWithoutRowId,
      };
      if (_notifyCallback != null) {
        _notifyCallback(true, methodGetServerInfo, result);
      }
      return result;
    });
    // Specific method for deleting a database
    _rpcServer.registerMethod(methodSqfliteDeleteDatabase,
        (json_rpc.Parameters parameters) async {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodSqfliteDeleteDatabase, parameters.value);
      }
      await _sqfliteServer.factory
          .deleteDatabase((parameters.value as Map)[keyPath] as String);
      if (_notifyCallback != null) {
        _notifyCallback(true, methodSqfliteDeleteDatabase, null);
      }
      return null;
    });
    // Specific method for creating a directory
    _rpcServer.registerMethod(methodCreateDirectory,
        (json_rpc.Parameters parameters) async {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodCreateDirectory, parameters.value);
      }
      var path = await _sqfliteServer.sqfliteLocalContext
          .createDirectory((parameters.value as Map)[keyPath] as String);
      if (_notifyCallback != null) {
        _notifyCallback(true, methodCreateDirectory, path);
      }
      return path;
    });
    // Specific method for deleting a directory
    _rpcServer.registerMethod(methodDeleteDirectory,
        (json_rpc.Parameters parameters) async {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodDeleteDirectory, parameters.value);
      }
      var path = await _sqfliteServer.sqfliteLocalContext
          .deleteDirectory((parameters.value as Map)[keyPath] as String);
      if (_notifyCallback != null) {
        _notifyCallback(true, methodDeleteDirectory, path);
      }
      return path;
    });
    // Specific method for writing a file
    _rpcServer.registerMethod(methodWriteFile,
        (json_rpc.Parameters parameters) async {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodWriteFile, parameters.value);
      }
      final map = parameters.value as Map;
      var path = map[keyPath]?.toString();
      var content = (map[keyContent] as List)?.cast<int>();
      path = await _sqfliteServer.sqfliteLocalContext.writeFile(path, content);
      if (_notifyCallback != null) {
        _notifyCallback(true, methodWriteFile, path);
      }
      return path;
    });
    // Specific method for deleting a directory
    _rpcServer.registerMethod(methodReadFile,
        (json_rpc.Parameters parameters) async {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodReadFile, parameters.value);
      }
      final map = parameters.value as Map;
      final path = map[keyPath] as String;

      var content = await _sqfliteServer.sqfliteLocalContext.readFile(path);
      if (_notifyCallback != null) {
        _notifyCallback(true, methodReadFile, content);
      }
      return content;
    });
    // Generic method
    _rpcServer.registerMethod(methodSqflite,
        (json_rpc.Parameters parameters) async {
      if (_notifyCallback != null) {
        _notifyCallback(false, methodSqflite, parameters.value);
      }

      var map = parameters.value as Map;

      var sqfliteMethod = map[keyMethod] as String;
      var sqfliteParam = map[keyParam];

      if (sqfliteMethod != null && sqfliteParam != null) {
        sqfliteParam = fixParam(sqfliteMethod, sqfliteParam);
      }

      dynamic result = await _sqfliteServer.invokeHandler
          .invokeMethod<dynamic>(sqfliteMethod, sqfliteParam);
      if (_notifyCallback != null) {
        _notifyCallback(true, methodSqflite, result);
      }

      // Store opened database
      if (sqfliteMethod == methodOpenDatabase) {
        if (result is Map) {
          _openDatabaseIds.add(result[paramId] as int);
        } else if (result is int) {
          // Old
          _openDatabaseIds.add(result);
        } else {
          throw 'invalid open result $result';
        }
      } else if (sqfliteMethod == methodCloseDatabase) {
        _openDatabaseIds.remove((sqfliteParam as Map)[paramId] as int);
      }

      return result;
    });
    _rpcServer.listen();

    // Cleanup
    // close opened database
    _rpcServer.done.then((_) async {
      for (var databaseId in _openDatabaseIds) {
        try {
          await _sqfliteServer.invokeHandler.invokeMethod<dynamic>(
              methodCloseDatabase, {paramId: databaseId});
        } catch (e) {
          print('error cleaning up database $databaseId');
        }
      }
    });
  }

  final SqfliteServer _sqfliteServer;
  final json_rpc.Server _rpcServer;

  SqfliteServerNotifyCallback get _notifyCallback =>
      _sqfliteServer._notifyCallback;
}

class SqfliteLocalContext implements SqfliteContext {
  @override
  final DatabaseFactory databaseFactory;

  SqfliteLocalContext({@required this.databaseFactory});

  @override
  Future<String> createDirectory(String path) async {
    try {
      path = await fixPath(path);
      await Directory(path).create(recursive: true);
    } catch (_e) {
      // print(e);
    }
    return path;
  }

  @override
  Future<String> deleteDirectory(String path) async {
    try {
      path = await fixPath(path);
      await Directory(path).delete(recursive: true);
    } catch (_e) {
      // print(e);
    }
    return path;
  }

  Future<String> fixPath(String path) async {
    if (path == null) {
      path = await databaseFactory.getDatabasesPath();
    } else if (path == inMemoryDatabasePath) {
      // nothing
    } else {
      if (isRelative(path)) {
        path = pathContext.join(await databaseFactory.getDatabasesPath(), path);
      }
      path = pathContext.absolute(pathContext.normalize(path));
    }
    return path;
  }

  @override
  bool get supportsWithoutRowId => Platform.isIOS;

  @override
  bool get isAndroid => Platform.isAndroid;

  @override
  bool get isIOS => Platform.isIOS;

  @override
  Context get pathContext => path.context;

  @override
  Future<List<int>> readFile(String path) async =>
      File(await fixPath(path)).readAsBytes();

  @override
  Future<String> writeFile(String path, List<int> data) async {
    path = await fixPath(path);
    await File(await fixPath(path)).writeAsBytes(data, flush: true);
    return path;
  }
}

T fixParam<T>(String method, T param) {
  switch (method) {
    //  [
    //          'insert',
    //          {
    //            'sql': 'INSERT INTO test (blob) VALUES (?)',
    //            'arguments': [
    //              [1, 2, 3]
    //            ],
    //            'id': 1
    //          },
    //          null
    //        ],
    case methodInsert:
    case methodUpdate:
    case methodQuery:
    case methodExecute:
      if (param is Map) {
        var arguments = param['arguments'];
        if (arguments is List) {
          for (var i = 0; i < arguments.length; i++) {
            var argument = arguments[i];
            if (argument is List && !(argument is Uint8List)) {
              // fix!
              arguments[i] = Uint8List.fromList(argument.cast<int>());
            }
          }
        }
      }
      break;
    //  [
    //          'batch',
    //          {
    //            'operations': [
    //              {
    //                'method': 'insert',
    //                'sql': 'INSERT INTO test (blob) VALUES (?)',
    //                'arguments': [
    //                  [1, 2, 3]
    //                ]
    //              }
    //            ],
    //            'id': 1
    //          },
    //          null
    //        ],
    case methodBatch:
      if (param is Map) {
        var operations = param['operations'];
        if (operations is List) {
          for (var operation in operations) {
            if (operation is Map) {
              var method = operation['method'] as String;
              fixParam(method, operation);
            }
          }
        }
      }
      break;
  }
  return param;
}
