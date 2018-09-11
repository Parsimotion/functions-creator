process.title = "functions-creator"

_ = require "lodash"
Promise = require "bluebird"

handlebars = require "handlebars"
layouts = require "handlebars-layouts"
handlebarsHelpers = require "handlebars-helpers"

fs = Promise.promisifyAll require "fs"
option = require "option"
beautify = require("js-beautify").js_beautify

args = require("args")

args
  .option("output", "Folder where the function will be generated", "./.build")
  .option("templates", "Folder with templates to use", "./templates")
  .option("functions", "Folder with metadata functions to create", "./functions")
  .option("processors", "Folder with processors to use", "./processors")
  .option("only-create-if-active", "It will only create the function if active", false);

options = args.parse process.argv

folders =
  _.pick options, [ "functions", "output", "templates", "processors" ]

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
  return Promise.resolve() if not config.active and options["onlyCreateIfActive"]

  outputFolder = "#{folders.output}/#{functionName}"
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
  return Promise.resolve() if not config.active and options["onlyCreateIfActive"]

  outputFolder = "#{folders.output}/#{functionName}-historic-deadletter"
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
  .tap -> _initFolder folders.output
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

    $promises = Promise.all [
      _createFunction { functionName, processor, regular: true, config: _.assign(active: option.fromNullable(jobs?.regular).valueOrElse(true), config) }
      _createFunction { functionName, processor, regular: false, config: _.assign(active: option.fromNullable(jobs?.deadletter).valueOrElse(true), config) }
      _createHistoricalDeadletterProcessor { functionName, processor, config: _.assign(
        active: option.fromNullable(jobs?.historicDeadletter).valueOrElse(false),
        schedule: option.fromNullable(jobs?.historicDeadletter?.schedule).valueOrElse "0 0 * */1 * *"
      , config)
      }
    ]

    if ((config.replicas or 0) > 0)
      _.times config.replicas, (n) ->
        _createFunction { functionName: "#{functionName}-replica-#{n + 1}", processor, regular: true, config: _.assign(active: option.fromNullable(jobs?.regular).valueOrElse(true), config) }
