process.title = "iwannabe"

_ = require "lodash"
Promise = require "bluebird"

handlebars = require "handlebars"
layouts = require "handlebars-layouts"
handlebarsHelpers = require "handlebars-helpers"

fs = Promise.promisifyAll require "fs"
beautify = require("js-beautify").js_beautify

folders =
  functions: "./functions"
  build: "./.build"
  templates: "./templates"

APP_FUNCTIONS = process.env.APPS_FUNCTIONS or "mercadolibre-functions"

newHandlebars = ->
  newHandlebar = handlebars.create()
  layouts.register newHandlebar
  handlebarsHelpers { handlebars: newHandlebar }
  newHandlebar

_initFolder = (path) ->
  __alreadyExist = (err) -> err.code is "EEXIST"

  fs.mkdirAsync path
  .catchReturn __alreadyExist, null

_readTemplate = (path) -> fs.readFileAsync(path, "utf8")

_generateTemplate = (handlebarsToUse, config) ->
  { template, output } = config
  _readTemplate("#{folders.templates}/#{template}.handlebars")
  .then handlebarsToUse.compile
  .then (template) -> template config
  .then (content) -> fs.writeFileAsync "#{output}", beautify(content, indent_size: 2)

_createFunction = ({ regular, functionName, processor, config }) ->
  outputFolder = "#{folders.build}/#{functionName}"
  outputFolder = "#{outputFolder}-deadletter" unless regular
  handlebarsToUse = newHandlebars()

  _initFolder outputFolder
  .then -> fs.readFileAsync "#{processor}", "utf8"
  .then (content) -> handlebarsToUse.registerPartial "processor", content
  .thenReturn ["index.js", "function.json"]
  .map (file) -> { file, template: "#{config.type}.#{file}" }
  .tap (files) -> files.push { file: "run.example.js", template: "function.run.example.js", }
  .map ({ file, template }) ->
    _.merge {
      functionName
      template
      app: APP_FUNCTIONS
      output: "#{outputFolder}/#{file}"
      regular
    }, config
  .map (config) -> _generateTemplate handlebarsToUse, config

_createHistoricalDeadletterProcessor = ({ functionName, processor, config }) ->
  outputFolder = "#{folders.build}/#{functionName}-historic-deadletter"
  handlebarsToUse = newHandlebars()

  _initFolder outputFolder
  .then -> fs.readFileAsync "#{processor}", "utf8"
  .then (content) -> handlebarsToUse.registerPartial "processor", content
  .then -> ["index.js", "function.json", "run.example.js"]
  .map (file) -> { file, template: "historical.errors.#{file}" }
  .map ({ file, template }) ->
     _.merge {
      functionName
      template
      app: APP_FUNCTIONS
      output: "#{outputFolder}/#{file}"
    }, config
  .map (config) -> _generateTemplate handlebarsToUse, config


Promise.resolve()
  .tap -> _initFolder folders.build
  .then -> fs.readdirAsync folders.functions
  .map (filePath) ->
    Promise.props {
      filePath
      config: fs.readFileAsync("#{folders.functions}/#{filePath}", "utf8")
    }
  .each (opts) -> _.update opts, "config", JSON.parse
  .each ({ filePath, config }) ->
    { jobs } = config
    processor = config.processor or "./processors/request.handlebars"
    functionName = filePath.replace ".json", ""

    Promise.all [
      _createFunction { functionName, processor, regular: true, config: _.merge({}, config, active: jobs?.regular or true) }
      _createFunction { functionName, processor, regular: false, config: _.merge({}, config, active: jobs?.deadletter or true) }
      _createHistoricalDeadletterProcessor { functionName, processor, config: _.merge({}, config,
        active: jobs?.historicDeadletter or false,
        schedule: jobs?.historicDeadletter?.schedule or "0 0 * */1 * *")
      }
    ]
