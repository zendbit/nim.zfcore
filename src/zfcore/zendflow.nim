#[
  ZendFlow web framework for nim language
  This framework if free to use and to modify
  License: BSD
  Author: Amru Rosyada
  Email: amru.rosyada@gmail.com
  Git: https://github.com/zendbit
]#

import
  asyncdispatch,
  strformat,
  tables,
  json,
  strtabs,
  os,
  times,
  asyncnet,
  net,
  strutils

import
  uri3

import
  router,
  route,
  httpctx,
  formdata,
  settings,
  fluentvalidation,
  zfblast,
  zfmacros

const ZF_SETTINGS_FILE* = "settings.json"

#[
  ZendFlow object definition
  this contain:
    server: is instance of AsyncHttpServer fo high performance httpserver
    r: is for routing object, we will use this for routing definition and will use it alot
    settings: is setting for the server contain setup for port, bind address, staticDir etc.
]#
type
  ZendFlow* = ref object
    # port to zfblast server
    # server: AsyncHttpServer
    server: ZFBlast
    r*: Router
    settings*: Settings
    isCleanTmpDirExecuted: bool

#[
  newZendFlow is for instantiate the zendflow framework contain parameter settings.
  default value will run on port 8080, bind address 0.0.0.0 and staticDir point to www folder
]#
proc newZendFlow*(settings: Settings): ZendFlow =
  return ZendFlow(
    server: newZFBlast(
      address = settings.address,
      port = Port(settings.port),
      reuseAddress = settings.reuseAddress,
      reusePort = settings.reusePort,
      maxBodyLength = settings.maxBodyLength,
      keepAliveMax = settings.keepAliveMax,
      keepAliveTimeout = settings.keepAliveTimeout,
      debug = settings.debug,
      sslSettings = settings.sslSettings),
    r: newRouter(),
    settings: settings)

proc zfJsonSettings*() : JsonNode =
  try:
    let sOp = open(ZF_SETTINGS_FILE)
    let settingsJson = sOp.readAll()
    sOp.close()
    return parseJson(settingsJson)

  except:
    return JsonNode()


# read setting from file
proc newZendFlow*(): ZendFlow =
  let settingsJson = zfJsonSettings()
  if settingsJson.len() != 0:
    let settings = newSettings()
    settings.sslSettings = SslSettings()
    var appRootDir = settingsJson{"appRootDir"}.getStr()
    if appRootDir != "":
      settings.appRootDir = appRootDir
    settings.keepAliveMax = settingsJson{"keepAliveMax"}.getInt()
    settings.keepAliveTimeout = settingsJson{"keepAliveTimeout"}.getInt()
    settings.maxBodyLength = settingsJson{"maxBodyLength"}.getInt()
    settings.debug = settingsJson{"debug"}.getBool()
    let httpSettings = settingsJson{"http"}
    if not isNil(httpSettings):
      settings.port = httpSettings{"port"}.getInt()
      settings.address = httpSettings{"address"}.getStr()
      settings.reuseAddress = httpSettings{"reuseAddress"}.getBool()
      settings.reusePort = httpSettings{"reusePort"}.getBool()
      let httpsSettings = httpSettings{"secure"}
      if not isNil(httpsSettings):
        settings.sslSettings.port = Port(httpsSettings{"port"}.getInt())
        settings.sslSettings.certFile = httpsSettings{"cert"}.getStr()
        settings.sslSettings.keyFile = httpsSettings{"key"}.getStr()
        settings.sslSettings.verify = httpSettings{"verify"}.getBool()


    return ZendFlow(
      server: newZFBlast(
        address = settings.address,
        port = Port(settings.port),
        reuseAddress = settings.reuseAddress,
        reusePort = settings.reusePort,
        maxBodyLength = settings.maxBodyLength,
        keepAliveMax = settings.keepAliveMax,
        keepAliveTimeout = settings.keepAliveTimeout,
        debug = settings.debug,
        sslSettings = settings.sslSettings),
      r: newRouter(),
      settings: settings)

  else:
    echo ""
    echo "Failed to load settings.json, using default settings."
    echo ""
    return ZendFlow(
      server: newZFBlast(
        address = "0.0.0.0",
        port = Port(8080),
        debug = false,
        reuseAddress = true,
        reusePort = false,
        sslSettings = nil,
        maxBodyLength = 268435456,
        keepAliveMax = 20,
        keepAliveTimeout = 10),
      r: newRouter(),
      settings: newSettings())

#[
  this proc is private and will to use if the route not found or not match with router definition
  the ctx:HttpContext is standard HttpContext from zfblast
]#
proc httpMethodNotFoundAsync(
  self: ZendFlow,
  ctx: HttpContext): Future[void] {.async.} =

  ctx.response.httpCode = Http500
  ctx.response.body =
    &"Request method not implemented: {ctx.request.httpMethod}"

  await ctx.send(ctx)

#[
  this proc is private for sending request context to router, the request will process and parsed
  to make decision wich route tobe executed, ctx:HttpContext is standard HttpContext from zfblast
]#
proc sendToRouter(
  self: ZendFlow,
  ctx: HttpContext): Future[void] {.async.} =

  try:
    await self.r.executeProc(ctx, self.settings)
  except Exception as ex:
    if self.settings.debug:
      asyncCheck dbg(proc () =
        echo ""
        echo "#== start"
        echo "#== zfcore debuger"
        echo ex.msg
        echo "#== end"
        echo "")

#[
  clean Tmp folder may take resource
  todo: should be have better approach for this method
]#
proc cleanTmpDir(
  self: ZendFlow,
  settings: Settings) =

  for file in walkFiles(settings.tmpDir & "*"):
    # get all files
    let timestamp = splitPath(file)[1].split('_')[0]
    let timeInterval = toUnix(getTime()) - parseBiggestInt(timestamp)
    if timeInterval div 3600 >= 1:
      discard tryRemoveFile(file)

#[
  this proc is private for main dispatch of request
]#
proc mainHandlerAsync(
  self: ZendFlow,
  ctx: HttpContext): Future[void] {.async.} =

  try:
    if ctx.request.httpmethod in [HttpGet, HttpPost, HttpPut, HttpPatch,
      HttpDelete, HttpHead, HttpTrace, HttpOptions, HttpConnect]:
      # set default headers content type
      ctx.response.headers["Content-Type"] = "text/plain; utf-8"

      await sendToRouter(self, ctx)
      # Chek cleanup tmp dir
      if not self.isCleanTmpDirExecuted:
        self.isCleanTmpDirExecuted = not self.isCleanTmpDirExecuted
        self.cleanTmpDir(self.settings)
        self.isCleanTmpDirExecuted = not self.isCleanTmpDirExecuted

    else:
      await httpMethodNotFoundAsync(self, ctx)

  except Exception as ex:
    if self.settings.debug:
      asyncCheck dbg(proc () =
        echo ""
        echo "#== start"
        echo "#== zfcore debuger"
        echo "Failed handle client request."
        echo ex.msg
        echo "#== end"
        echo "")

#[
  this proc is for start the ZendFlow, this will serve forever :-)
]#
proc serve*(self: ZendFlow) =

  echo "Enjoy and take a cup of coffe :-)"

  waitFor self.server.serve(proc (ctx: HttpContext): Future[void] {.async.} =
    asyncCheck self.mainHandlerAsync(ctx))

export
  asyncdispatch,
  tables,
  json,
  strtabs,
  strutils,
  times,
  os,
  asyncnet

export
  uri3

export
  httpCtx,
  router,
  route,
  formData,
  settings,
  fluentValidation,
  zfblast,
  zfMacros