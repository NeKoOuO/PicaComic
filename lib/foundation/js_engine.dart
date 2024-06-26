import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/tools/extensions.dart';

class JavaScriptRuntimeException implements Exception {
  final String message;

  JavaScriptRuntimeException(this.message);

  @override
  String toString() {
    return "JSException: $message";
  }
}

class JsEngine with _JSEngineApi{
  factory JsEngine() => _cache ?? (_cache = JsEngine._create());

  static JsEngine? _cache;

  JsEngine._create() {
    _init();
  }

  JavascriptRuntime? _jsRuntime;

  bool _closed = true;

  Dio? _dio;

  int _messageKey = 0;

  final Map<int, dynamic> _responseData = {};

  final _networkRequests = <Map<String, dynamic>>[];

  void _init() {
    if (!_closed) {
      return;
    }
    _closed = false;
    _jsRuntime = getJavascriptRuntime(xhr: false);
    _jsRuntime!.onMessage("message", _messageReceiver);
    var res = _jsRuntime!.evaluate(_jsInit);
    if(res.isError){
      log("Failed to init JS Engine: \n $res", "JsEngine", LogLevel.error);
    }
    _loop();
  }

  dynamic _messageReceiver(dynamic message) {
    try {
      if (message is Map<String, dynamic>) {
        String method = message["method"];
        switch (method) {
          case "log":
            {
              String level = message["level"];
              LogManager.addLog(
                  switch (level) {
                    "error" => LogLevel.error,
                    "warning" => LogLevel.warning,
                    "info" => LogLevel.info,
                    _ => LogLevel.warning
                  },
                  message["title"],
                  message["content"]);
            }
          case 'return':
            {
              int key = message["key"];

              if(_responseData[key] != null){
                return;
              }

              if (message["data"] != null) {
                _responseData[key] = message["data"];
              } else {
                _responseData[key] = JavaScriptRuntimeException(
                    message["errorMessage"] ?? "Unknown error");
              }
              Future.delayed(
                  const Duration(seconds: 20), () => _responseData[key] = null);
            }
          case 'load_data':
            {
              String key = message["key"];
              String dataKey = message["data_key"];
              return ComicSource.sources
                  .firstWhereOrNull((element) => element.key == key)
                  ?.data[dataKey];
            }

          case 'save_data':
            {
              String key = message["key"];
              String dataKey = message["data_key"];
              var data = message["data"];
              var source = ComicSource.sources
                  .firstWhere((element) => element.key == key);
              source.data[dataKey] = data;
              source.saveData();
            }
          case 'http':
            {
              _networkRequests.add(message);
            }
          case 'html':
            {
              return handleHtmlCallback(message);
            }
          case 'convert':
            {
              return _convert(message);
            }
          case "random":
            {
              return _randomInt(message["min"], message["max"]);
            }
        }
      }
    }
    catch(e, s){
      log("Failed to handle message: $message\n$e\n$s", "JsEngine", LogLevel.error);
      rethrow;
    }
  }

  void _loop() async {
    _dio ??= logDio(BaseOptions(
        responseType: ResponseType.plain, validateStatus: (status) => true));
    _cookieJar ??= SingleInstanceCookieJar.instance!;
    _dio!.interceptors.add(CookieManagerSql(_cookieJar!));

    while (_jsRuntime != null) {
      if (_closed) return;

      _jsRuntime!.executePendingJob();

      _handleHttpRequests();

      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  void _handleHttpRequests(){
    var requests = List<Map<String, dynamic>>.from(_networkRequests);

    _networkRequests.clear();

    for (var req in requests) {
      Future.sync(() async {
        Response<String>? response;
        String? error;

        try {
          var headers = Map<String, dynamic>.from(req["headers"] ?? {});
          if(headers["user-agent"] == null && headers["User-Agent"] == null){
            headers["User-Agent"] = webUA;
          }
          response = switch (req["http_method"]) {
            "GET" =>
            await _dio!.get<String>(
              req["url"],
              options: Options(headers: headers),
            ),
            "POST" =>
            await _dio!.post<String>(
              req["url"],
              data: req["data"],
              options: Options(headers: headers),
            ),
            "PUT" =>
            await _dio!.put<String>(
              req["url"],
              data: req["data"],
              options: Options(headers: headers),
            ),
            "PATCH" =>
            await _dio!.patch<String>(
              req["url"],
              data: req["data"],
              options: Options(headers: headers),
            ),
            "DELETE" =>
            await _dio!.delete<String>(
              req["url"],
              options: Options(headers: headers),
            ),
            _ => throw "Unknown http method: ${req["http_method"]}",
          };
        } catch (e) {
          error = e.toString();
        }

        Map<String, String> headers = {};

        response?.headers.forEach((name, values) => headers[name] = values.join(','));

        var res = _jsRuntime?.evaluate(
          "Network.responseCallback("
              "${req["requestId"]}, "
              "${response?.statusCode}, "
              "${jsonEncode(headers)}, "
              "${jsonEncode(response?.data)}, "
              "${jsonEncode(error)});",
        );
        if(res?.isError ?? false){
          log("Failed to send network result to JS Engine: \n $res", "JS Engine", LogLevel.error);
        }
      });
    }
  }

  void runCode(String js) {
    var res = _jsRuntime!.evaluate(js);

    if (res.isError) {
      throw res.rawResult;
    }
  }

  void runCodeProtected(String js) {
    var res = _jsRuntime!.evaluate('''
      function pica_protected_zone(){
        $js
      }
      pica_protected_zone();
    ''');

    if (res.isError) {
      throw res.rawResult;
    }
  }

  Future<int> runProtectedWithKey(String js, String key) async {
    _messageKey++;

    var res = await _jsRuntime!.evaluateAsync('''
      function pica_protected_zone(){
        function success(data){
          sendMessage('message', JSON.stringify({
            method: 'return',
            data: data,
            key: $_messageKey,
          }));
        }
        function error(data){
          sendMessage('message', JSON.stringify({
            method: 'return',
            errorMessage: data,
            key: $_messageKey,
          }));
        }
        function loadData(key){
          return sendMessage('message', JSON.stringify({
              method: 'load_data',
              key: '$key',
              data_key: key,
          }));
        }
        function setData(key, data){
            return sendMessage('message', JSON.stringify({
                method: 'save_data',
                key: '$key',
                data_key: key,
                data: data
            }));
        }
        $js
      }
      pica_protected_zone();
    ''');

    if (res.isError) {
      throw res.rawResult;
    }

    return _messageKey;
  }

  void dispose() {
    _cache = null;
    _closed = true;
    _jsRuntime!.dispose();
  }

  Future<dynamic> wait(int key) async {
    for (int i = 0; i < 20; i++) {
      if (_responseData[key] != null) {
        if (_responseData[key] is Exception) {
          throw _responseData[key];
        }
        clear();
        return _responseData[key];
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    clear();
    throw JavaScriptRuntimeException("Timeout");
  }
}

mixin class _JSEngineApi{
  final Map<int, dom.Document> _documents = {};
  final Map<int, dom.Element> _elements = {};
  CookieJarSql? _cookieJar;

  dynamic handleHtmlCallback(Map<String, dynamic> data) {
    switch (data["function"]) {
      case "parse":
        _documents[data["key"]] = html.parse(data["data"]);
        return null;
      case "querySelector":
        var res = _documents[data["key"]]!.querySelector(data["query"]);
        if(res == null) return null;
        _elements[_elements.length] = res;
        return _elements.length - 1;
      case "querySelectorAll":
        var res = _documents[data["key"]]!.querySelectorAll(data["query"]);
        var keys = <int>[];
        for(var element in res){
          _elements[_elements.length] = element;
          keys.add(_elements.length - 1);
        }
        return keys;
      case "getText":
        return _elements[data["key"]]!.text;
      case "getAttributes":
        return _elements[data["key"]]!.attributes;
      case "dom_querySelector":
        var res = _elements[data["key"]]!.querySelector(data["query"]);
        if(res == null) return null;
        _elements[_elements.length] = res;
        return _elements.length - 1;
      case "dom_querySelectorAll":
        var res = _elements[data["key"]]!.querySelectorAll(data["query"]);
        var keys = <int>[];
        for(var element in res){
          _elements[_elements.length] = element;
          keys.add(_elements.length - 1);
        }
        return keys;
      case "children":
        var res = _elements[data["key"]]!.children;
        var keys = <int>[];
        for(var element in res){
          _elements[_elements.length] = element;
          keys.add(_elements.length - 1);
        }
        return keys;
    }
  }

  dynamic handleCookieCallback(Map<String, dynamic> data) {
    switch (data["function"]) {
      case "set":
        _cookieJar!.saveFromResponse(
            Uri.parse(data["url"]),
            (data["cookies"] as List).map(
                    (e) => Cookie(e["name"], e["value"])).toList());
        return null;
      case "get":
        return Future(() async{
          var cookies = await _cookieJar!.loadForRequest(Uri.parse(data["url"]));
          return cookies.map((e) => {
            "name": e.name,
            "value": e.value,
            "domain": e.domain,
            "path": e.path,
            "expires": e.expires,
            "max-age": e.maxAge,
            "secure": e.secure,
            "httpOnly": e.httpOnly,
            "session": e.expires == null,
          }).toList();
        });
    }
  }

  void clear(){
    _documents.clear();
    _elements.clear();
  }

  void clearCookies(List<String> domains) async{
    for(var domain in domains){
      var uri = Uri.tryParse(domain);
      if(uri == null) continue;
      _cookieJar!.deleteUri(uri);
    }
  }

  String _convert(Map<String, dynamic> data) {
    String type = data["type"];
    String value = data["value"];
    bool isEncode = data["isEncode"];
    switch (type) {
      case "base64":
        return isEncode ? base64Encode(utf8.encode(value)) : utf8.decode(base64Decode(value));
      case "md5":
        return isEncode ? md5.convert(utf8.encode(value)).toString() : value;
      default:
        return value;
    }
  }

  int _randomInt(int min, int max) {
    return (min + (max - min) * math.Random().nextDouble()).toInt();
  }
}

const _jsInit = '''
class NetworkResponse {
    constructor(status, headers, body) {
        this.status = status;
        this.headers = headers;
        this.body = body;
    }
}

class Convert {    
    static encodeBase64(value) {
        return sendMessage('message', JSON.stringify({
            method: "convert",
            type: "base64",
            value: value,
            isEncode: true
        }));
    }
    
    static decodeBase64(value) {
        return sendMessage('message', JSON.stringify({
            method: "convert",
            type: "base64",
            value: value,
            isEncode: false
        }));
    }

    static md5(value) {
        return sendMessage('message', JSON.stringify({
            method: "convert",
            type: "md5",
            value: value,
            isEncode: true
        }));
    }
}

function randomInt(min, max) {
    return sendMessage('message', JSON.stringify({
        method: 'random',                               
        min: min,
        max: max
    }));
}

class _Timer{
    delay = 0;

    callback = () => {};

    status = false;

    constructor(delay, callback) {
        this.delay = delay;
        this.callback = callback;
    }

    run(){
        this.status = true;
        this._interval();
    }

    _interval(){
        if(!this.status){
            return;
        }
        this.callback();
        setTimeout(this._interval.bind(this), this.delay);
    }

    cancel(){
        this.status = false;
    }
}

function setInterval(callback, delay) {
    let timer = new _Timer(delay, callback);
    timer.run();
    return timer;
}

class Network {
    static requestId = 0;

    static requestResponse = {};

    static responseCallback(id, status, headers, body, error) {
        this.requestResponse[id] = {
            status: status,
            headers: headers,
            body: body,
            error: error
        };
    }

    static async sendRequest(method, url, headers, data) {
        this.requestId++;
        let id = this.requestId;
        return new Promise((resolve, reject) => {
            sendMessage('message', JSON.stringify({
                method: 'http',
                requestId: id,
                http_method: method,
                url: url,
                headers: headers,
                data: data
            }))
            // max wait time 10s
            let timeout = 100;

            let interval = setInterval(() => {
                timeout--;
                if (timeout <= 0) {
                    interval.cancel();
                    reject(`Http Request Timeout: url: \${url}; method: \${method}; id: \${id}`);
                }
                if (this.requestResponse[id] !== undefined) {
                    interval.cancel();
                    let response = this.requestResponse[id];
                    delete this.requestResponse[id];
                    log("info", "JS Engine", `Receive http response: url: \${url}; method: \${method}; id: \${id}`);
                    if(response.error !== undefined && response.error !== null){
                        reject(response.error)
                    } else {
                        resolve(new NetworkResponse(response.status, response.headers, response.body));
                    }
                }
            }, 100);
        });
    }

    static async get(url, headers) {
        return this.sendRequest('GET', url, headers);
    }

    static async post(url, headers, data) {
        return this.sendRequest('POST', url, headers, data);
    }

    static async put(url, headers, data) {
        return this.sendRequest('PUT', url, headers, data);
    }

    static async patch(url, headers, data) {
        return this.sendRequest('PATCH', url, headers, data);
    }
    
    static async delete(url, headers) {
        return this.sendRequest('DELETE', url, headers);
    }
}

class HtmlDocument{
    static _key = 0;

    key = 0;

    constructor(html) {
        this.key = HtmlDocument._key;
        HtmlDocument._key++;
        sendMessage('message', JSON.stringify({
            method: "html",
            function: "parse",
            key: this.key,
            data: html
        }))
    }

    querySelector(query){
        let k = sendMessage('message', JSON.stringify({
            method: "html",
            function: "querySelector",
            key: this.key,
            query: query
        }))
        return new HtmlDom(k);
    }

    querySelectorAll(query) {
        let ks = sendMessage('message', JSON.stringify({
            method: "html",
            function: "querySelectorAll",
            key: this.key,
            query: query
        }))
        return ks.map(k => new HtmlDom(k));
    }
}

class HtmlDom{
    key = 0;

    constructor(k){
        this.key = k;
    }

    get text(){
        return sendMessage('message', JSON.stringify({
            method: "html",
            function: "getText",
            key: this.key
        }))
    }

    get attributes(){
        return sendMessage('message', JSON.stringify({
            method: "html",
            function: "getAttributes",
            key: this.key
        }))
    }

    querySelector(query){
        let k = sendMessage('message', JSON.stringify({
            method: "html",
            function: "dom_querySelector",
            key: this.key,
            query: query
        }))
        return new HtmlDom(k);
    }

    querySelectorAll(query) {
        let ks = sendMessage('message', JSON.stringify({
            method: "html",
            function: "dom_querySelectorAll",
            key: this.key,
            query: query
        }))
        return ks.map(k => new HtmlDom(k));
    }

    get children(){
        let ks = sendMessage('message', JSON.stringify({
            method: "html",
            function: "getChildren",
            key: this.key
        }))
        return ks.map(k => new HtmlDom(k));
    }
}

function log(level, title, content){
    sendMessage('message', JSON.stringify({
        method: 'log',
        level: level,
        title: title,
        content: content,
    }))
}

let tempData = {}

''';