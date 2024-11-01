VERSION = "0.1.0"

local micro = import("micro")
local config = import("micro/config")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local util = import("micro/util")
local go_os = import("os")
local go_strings = import("strings")
local go_time = import("time")

local settings = settings
local json = json

function init()
    micro.SetStatusInfoFn("mlsp.status")
    config.MakeCommand("lsp", startServer, config.NoComplete)
    config.MakeCommand("lsp-stop", stopServers, config.NoComplete)
    config.MakeCommand("lsp-showlog", showLog, config.NoComplete)
    config.MakeCommand("lsp-update", contentUpdate, config.NoComplete)
    config.MakeCommand("hover", hoverAction, config.NoComplete)
    config.MakeCommand("format", formatAction, config.NoComplete)
    config.MakeCommand("autocomplete", completionAction, config.NoComplete)
    config.MakeCommand("goto-definition", gotoAction("definition"), config.NoComplete)
    config.MakeCommand("goto-declaration", gotoAction("declaration"), config.NoComplete)
    config.MakeCommand("goto-typedefinition", gotoAction("typeDefinition"), config.NoComplete)
    config.MakeCommand("goto-implementation", gotoAction("implementation"), config.NoComplete)
    config.MakeCommand("find-references", findReferencesAction, config.NoComplete)
    config.MakeCommand("document-symbols", documentSymbolsAction, config.NoComplete)
    config.MakeCommand("diagnostic-info", openDiagnosticBufferAction, config.NoComplete)
end

local activeConnections = {}
local allConnections = {}
setmetatable(allConnections, { __index = function (_, k) return activeConnections[k] end })
local docBuffers = {}
local lastAutocompletion = -1

local LSPClient = {}
LSPClient.__index = LSPClient

local LSPRange = {
    fromSelection = function(selection)
        -- create Range https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#range
        -- from [2]Loc https://pkg.go.dev/github.com/zyedidia/micro/v2@v2.0.12/internal/buffer#Cursor
        return {
            ["start"] = { line = selection[1].Y, character = selection[1].X },
            ["end"]   = { line = selection[2].Y, character = selection[2].X }
        }
    end,
    fromDelta = function(delta)
        local deltaEnd = delta.End
        -- for some reason delta.End is often 0,0 when inserting characters
        if deltaEnd.Y == 0 and deltaEnd.X == 0 then
            deltaEnd = delta.Start
        end

        return {
            ["start"] = { line = delta.Start.Y, character = delta.Start.X },
            ["end"]   = { line = deltaEnd.Y, character = deltaEnd.X }
        }
    end,
    toLocs = function(range)
        local a, b = range["start"], range["end"]
        return buffer.Loc(a.character, a.line), buffer.Loc(b.character, b.line)
    end
}

function status(buf)
    local servers = {}
    for _, client in pairs(activeConnections) do
        table.insert(servers, client.clientId)
    end
    if #servers == 0 then
        return "off"
    elseif #servers == 1 then
        return servers[1]
    else
        return string.format("[%s]", table.concat(servers, ","))
    end
end

function startServer(bufpane, argsUserdata)

    local args = {}
    for _, a in userdataIterator(argsUserdata) do
        table.insert(args, a)
    end

    local server
    if next(args) ~= nil then
        local cmd = table.remove(args, 1)
        -- prefer languageServer with given name from config.lua if no args given
        if next(args) == nil and languageServer[cmd] ~= nil then
            server = languageServer[cmd]
        else
            server = languageServer[cmd] or { cmd = cmd, args = args }
        end
    else
        local ftype = bufpane.Buf:FileType()
        server = settings.defaultLanguageServer[ftype]
        if server == nil then
            infobar(string.format("ERROR: no language server set up for file type '%s'", ftype))
            return
        end
    end

    LSPClient:initialize(server)
end

function stopServers(bufpane, argsUserdata)
    local hasArgs, name = pcall(function() return argsUserdata[1] end)

    local stoppedClients = {}
    if not hasArgs then -- stop all
        for clientId, client in pairs(activeConnections) do
            client:stop()
        end
        activeConnections = {}
    elseif activeConnections[name] then
        activeConnections[name]:stop()
        activeConnections[name] = nil
    else
        infobar(string.format("ERROR: unable to find active language server with name '%s'", name))
    end
end

function showLog(bufpane, args)
    local hasArgs, name = pcall(function() return args[1] end)

    for _, client in pairs(activeConnections) do
        if not hasArgs or client.name == name then
            foundClient = client
            break
        end
    end

    if foundClient == nil then
        infobar("no LSP client found")
        return
    end

    if foundClient.stderr == "" then
        infobar(foundClient.clientId .. " has not written anything to stderr")
        return
    end

    local title = string.format("Log for '%s' (%s)", foundClient.name, foundClient.clientId)
    local newBuffer = buffer.NewBuffer(foundClient.stderr, title)

    newBuffer:SetOption("filetype", "text")
    newBuffer.Type.scratch = true
    newBuffer.Type.Readonly = true

    micro.CurPane():HSplitBuf(newBuffer)
end

function LSPClient:initialize(server)
    local clientId = server.shortName or server.cmd

    if allConnections[clientId] ~= nil then
        infobar(string.format("%s is already running", clientId))
        return
    end

    local client = {}
    setmetatable(client, LSPClient)

    allConnections[clientId] = client

    client.clientId = clientId
    client.requestId = 0
    client.stderr = ""
    client.buffer = ""
    client.expectedLength = nil
    client.serverCapabilities = {}
    client.serverName = nil
    client.serverVersion = nil
    client.sentRequests = {}
    client.openFiles = {}
    client.onInitialized = server.onInitialized

    log(string.format("Starting '%s' with args", server.cmd), server.args)

    -- the last parameter(s) to JobSpawn are userargs which get passed down to
    -- the callback functions (onStdout, onStderr, onExit)
    client.job = shell.JobSpawn(server.cmd, server.args, onStdout, onStderr, onExit, clientId)

    if client.job.Err ~= nil then
        infobar(string.format("Error: %s", client.job.Err:Error()))
    end

    local wd, _ = go_os.Getwd()
    local rootUri = string.format("file://%s", wd:uriEncode())

    local params = {
        processId = go_os.Getpid(),
        rootUri = rootUri,
        workspaceFolders = { { name = "root", uri = rootUri } },
        capabilities = {
            textDocument = {
                synchronization = { didSave = true, willSave = false },
                hover = { contentFormat = {"plaintext"} },
                completion = {
                    completionItem = {
                        snippetSupport = false,
                        documentationFormat = {},
                    },
                    contextSupport = true
                }
            }
        }
    }
    if server.initializationOptions ~= nil then
        params.initializationOptions = server.initializationOptions
    end

    client:request("initialize", params)
    return client
end

function LSPClient:stop()
    for filePath, _ in pairs(self.openFiles) do
        for _, docBuf in ipairs(docBuffers[filePath]) do
            docBuf:ClearMessages(self.clientId)
        end
    end
    shell.JobStop(self.job)
end

function LSPClient:send(msg)
    msg = json.encode(msg)
    local msgWithHeaders = string.format("Content-Length: %d\r\n\r\n%s", #msg, msg)
    shell.JobSend(self.job, msgWithHeaders)
    log("(", self.clientId, ")->", msgWithHeaders, "\n\n")
end

function LSPClient:notification(method, params)
    local msg = {
        jsonrpc = "2.0",
        method = method
    }
    if params ~= nil then
        msg.params = params
    else
        -- the spec allows params to be omitted but language server implementations
        -- are buggy so we can put an empty object there for now
        -- https://github.com/golang/go/issues/57459
        msg.params = json.object
    end
    self:send(msg)
end

function LSPClient:request(method, params)
    local msg = {
        jsonrpc = "2.0",
        id = self.requestId,
        method = method
    }
    if params ~= nil then
        msg.params = params
    else
        -- the spec allows params to be omitted but language server implementations
        -- are buggy so we can put an empty object there for now
        -- https://github.com/golang/go/issues/57459
        msg.params = json.object
    end
    self.sentRequests[self.requestId] = method
    self.requestId = self.requestId + 1
    self:send(msg)
end

function LSPClient:handleResponseError(method, error)
    infobar(string.format("%s (Error %d, %s)", error.message, error.code, method))

    if method == "textDocument/completion" then
        setCompletions({})
    end
end

function LSPClient:handleResponseResult(method, result)
    if method == "initialize" then
        self.serverCapabilities = result.capabilities
        if result.serverInfo then
            self.serverName = result.serverInfo.name
            self.serverVersion = result.serverInfo.version
            infobar(string.format("Initialized %s version %s", self.serverName, self.serverVersion))
        else
            infobar(string.format("Initialized '%s' (no version information)", self.clientId))
        end
        self:notification("initialized")
        activeConnections[self.clientId] = self
        allConnections[self.clientId] = nil
        if type(self.onInitialized) == "function" then
            self:onInitialized()
        end
        -- FIXME: iterate over *all* currently open buffers
        onBufferOpen(micro.CurPane().Buf)
    elseif method == "textDocument/hover" then
        -- result.contents being a string or array is deprecated but as of 2023
        -- * pylsp still responds with {"contents": ""} for no results
        -- * lua-lsp still responds with {"contents": []} for no results
        if result == nil or result.contents == "" or table.empty(result.contents) then
            infobar("no hover results")
        elseif type(result.contents) == "string" then
            infobar(result.contents)
        elseif type(result.contents.value) == "string" then
            infobar(result.contents.value)
        else
            infobar("WARNING: ignored textDocument/hover result due to unrecognized format")
        end
    elseif method == "textDocument/formatting" then
        if result == nil or next(result) == nil then
            infobar("formatted file (no changes)")
        else
            local textedits = result
            editBuf(micro.CurPane().Buf, textedits)
            infobar("formatted file")
        end
    elseif method == "textDocument/rangeFormatting" then
        if result == nil or next(result) == nil then
            infobar("formatted selection (no changes)")
        else
            local textedits = result
            editBuf(micro.CurPane().Buf, textedits)
            infobar("formatted selection")
        end
    elseif method == "textDocument/completion" then
        -- TODO: handle result.isIncomplete = true somehow
        local completions = {}

        if result ~= nil then
            -- result can be either CompletionItem[] or an object
            -- { isIncomplete: bool, items: CompletionItem[] }
            completions = result.items or result
        end

        if #completions == 0 then
            infobar("no completions")
            setCompletions({})
            return
        end

        local cursor = micro.CurPane().Buf:GetActiveCursor()
        local backward = cursor.X
        while backward > 0 and util.IsWordChar(util.RuneStr(cursor:RuneUnder(backward-1))) do
            backward = backward - 1
        end

        cursor:SetSelectionStart(buffer.Loc(backward, cursor.Y))
        cursor:SetSelectionEnd(buffer.Loc(cursor.X, cursor.Y))

        local completionList = {}

        if self.serverName == "rust-analyzer" then
            -- unlike any other language server I've tried, rust-analyzer gives
            -- completions that don't start with current stem, end with special
            -- characters (eg. self::) and also occasionally contain duplicates
            -- (same identifier from different namespace)

            local stem = cursor:GetSelection()
            stem = util.String(stem)

            local uniqueCompletions = {}
            for _, completionItem in pairs(completions) do
                local item = completionItem.insertText or completionItem.label
                -- FIXME: micro's autocomplete doesn't deal well with non-alnum
                -- completions so we are currently just discarding them
                if item:match("^[%a%d_]+$") and item:startsWith(stem) then
                    uniqueCompletions[item] = 1
                end
            end

            for c, _ in pairs(uniqueCompletions) do
                table.insert(completionList, c)
            end
        else
            for _, completionItem in pairs(completions) do
                local item = completionItem.insertText or completionItem.label
                table.insert(completionList, item)
            end
        end

        cursor:DeleteSelection()
        setCompletions(completionList)

    elseif method == "textDocument/references" then
        if result == nil or table.empty(result) then
            infobar("No references found")
            return
        end
        showLocations("references", result)
    elseif
        method == "textDocument/declaration" or
        method == "textDocument/definition" or
        method == "textDocument/typeDefinition" or
        method == "textDocument/implementation"
    then
        -- result: Location | Location[] | LocationLink[] | null
        if result == nil or table.empty(result) then
            infobar(string.format("%s not found", method:match("textDocument/(.*)$")))
        else
            -- FIXME: handle list of results properly
            -- if result is a list just take the first one
            if result[1] then result = result[1] end

            -- FIXME: support LocationLink[]
            if result.targetRange ~= nil then
                infobar("LocationLinks are not supported yet")
                return
            end

            -- now result should be Location
            local filepath = absPathFromFileUri(result.uri)
            local startLoc, _ = LSPRange.toLocs(result.range)

            openFileAtLoc(filepath, startLoc)
        end
    elseif method == "textDocument/documentSymbol" then
        if result == nil or table.empty(result) then
            infobar("No symbols found in current document")
            return
        end
        local symbolLocations = {}
        local symbolLabels = {}
        local SYMBOLKINDS = {
	        [1] = "File",
	        [2] = "Module",
	        [3] = "Namespace",
	        [4] = "Package",
	        [5] = "Class",
	        [6] = "Method",
	        [7] = "Property",
	        [8] = "Field",
	        [9] = "Constructor",
	        [10] = "Enum",
	        [11] = "Interface",
	        [12] = "Function",
	        [13] = "Variable",
	        [14] = "Constant",
	        [15] = "String",
	        [16] = "Number",
	        [17] = "Boolean",
	        [18] = "Array",
	        [19] = "Object",
	        [20] = "Key",
	        [21] = "Null",
	        [22] = "EnumMember",
	        [23] = "Struct",
	        [24] = "Event",
	        [25] = "Operator",
	        [26] = "TypeParameter",
        }
        for _, sym in ipairs(result) do
            -- if sym.location is missing we are dealing with DocumentSymbol[]
            -- instead of SymbolInformation[]
            if sym.location == nil then
                table.insert(symbolLocations, {
                    uri = micro.CurPane().Buf.Path,
                    range = sym.range
                })
            else
                table.insert(symbolLocations, sym.location)
            end
            table.insert(symbolLabels, string.format("[%s]\t%s", SYMBOLKINDS[sym.kind], sym.name))
        end
        showLocations("document symbols", symbolLocations, symbolLabels)
    else
        log("WARNING: dunno what to do with response to", method)
    end
end

function LSPClient:handleNotification(notification)
    if notification.method == "textDocument/publishDiagnostics" then
        local filePath = absPathFromFileUri(notification.params.uri)

        if self.openFiles[filePath] == nil then
            log("DEBUG: received diagnostics for document that is not open:", filePath)
            return
        end

        local docVersion = notification.params.version
        if docVersion ~= nil and docVersion ~= self.openFiles[filePath].version then
            log("WARNING: received diagnostics for outdated version of document")
            return
        end

        self.openFiles[filePath].diagnostics = notification.params.diagnostics

        -- in the usual case there is only one buffer with the same document so a loop
        -- would not be necessary, but there may sometimes be multiple buffers with the
        -- same exact document open!
        for _, buf in ipairs(docBuffers[filePath]) do
            showDiagnostics(buf, self.clientId, notification.params.diagnostics)
        end
    elseif notification.method == "window/showMessage" then
        -- notification.params.type can be 1 = error, 2 = warning, 3 = info, 4 = log, 5 = debug
        if notification.params.type < 3 then
            infobar(notification.params.message)
        end
    elseif notification.method == "window/logMessage" then
        -- TODO: somehow include these messages in `lsp-showlog`
    else
        log("WARNING: don't know what to do with that message")
    end
end

function LSPClient:receiveMessage(text)
    local decodedMsg = json.decode(text)
    local request = self.sentRequests[decodedMsg.id]
    if request then
        self.sentRequests[decodedMsg.id] = nil
        if decodedMsg.error then
            self:handleResponseError(request, decodedMsg.error)
        else
            self:handleResponseResult(request, decodedMsg.result)
        end
    else
        self:handleNotification(decodedMsg)
    end
end

function LSPClient:textDocumentIdentifier(buf)
    return { uri = string.format("file://%s", buf.AbsPath:uriEncode()) }
end

function LSPClient:didOpen(buf)
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    -- if file is already open, do nothing
    if self.openFiles[filePath] ~= nil then
        return
    end

    local bufText = util.String(buf:Bytes())
    self.openFiles[filePath] = {
        version = 1,
        diagnostics = {}
    }
    textDocument.languageId = buf:FileType()
    textDocument.version = 1
    textDocument.text = bufText

    self:notification("textDocument/didOpen", {
        textDocument = textDocument
    })
end

function LSPClient:didClose(buf)
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] ~= nil then
        self.openFiles[filePath] = nil

        self:notification("textDocument/didClose", {
            textDocument = textDocument
        })
    end
end

function LSPClient:didChange(buf, changes)
    local textDocument = self:textDocumentIdentifier(buf)
    local filePath = buf.AbsPath

    if self.openFiles[filePath] == nil then
        log("ERROR: tried to emit didChange event for document that was not open")
        return
    end

    local newVersion = self.openFiles[filePath].version + 1

    self.openFiles[filePath].version = newVersion
    textDocument.version = newVersion

    self:notification("textDocument/didChange", {
        textDocument = textDocument,
        contentChanges = changes
    })
end

function LSPClient:didSave(buf)
    local textDocument = self:textDocumentIdentifier(buf)

    self:notification("textDocument/didSave", {
        textDocument = textDocument
    })
end

function LSPClient:onStdout(text)

    -- TODO: figure out if this is a performance bottleneck when receiving long
    -- messages (tens of thousands of bytes) – I suspect Go's buffers would be
    -- much faster than Lua string concatenation
    self.buffer = self.buffer .. text

    while true do
        if self.expectedLength == nil then
            -- receive headers
            -- TODO: figure out if it's necessary to handle the Content-Type header
            local a, b = self.buffer:find("\r\n\r\n")
            if a == nil then return end
            local headers = self.buffer:sub(0, a)
            local _, _, m = headers:find("Content%-Length: (%d+)")
            self.expectedLength = tonumber(m)
            self.buffer = self.buffer:sub(b+1)

        elseif self.buffer:len() < self.expectedLength then
            return

        else
            -- receive content
            self:receiveMessage(self.buffer:sub(0, self.expectedLength))
            self.buffer = self.buffer:sub(self.expectedLength + 1)
            self.expectedLength = nil
        end
    end
end

function log(...)
    micro.Log("[µlsp]", unpack(arg))
end

function infobar(text)
    micro.InfoBar():Message("[µlsp] " .. text:gsub("(%a)\n(%a)", "%1 / %2"):gsub("%s+", " "))
end



-- USER TRIGGERED ACTIONS
function hoverAction(bufpane)
    local client = findClientWithCapability("hoverProvider", "hover information")
    if client ~= nil then
        local buf = bufpane.Buf
        local cursor = buf:GetActiveCursor()
        client:request("textDocument/hover", {
            textDocument = client:textDocumentIdentifier(buf),
            position = { line = cursor.Y, character = cursor.X }
        })
    end
end

function formatAction(bufpane)
    local buf = bufpane.Buf
    local selectedRanges = {}

    for i = 1, #buf:GetCursors() do
        local cursor = buf:GetCursor(i - 1)
        if cursor:HasSelection() then
            table.insert(selectedRanges, LSPRange.fromSelection(cursor.CurSelection))
        end
    end

    if #selectedRanges > 1 then
        infobar("formatting multiple selections is not supported yet")
        return
    end

    local formatOptions = {
        -- most servers completely ignore these values but tabSize and
        -- insertSpaces are required according to the specification
        -- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#formattingOptions
        tabSize = buf.Settings["tabsize"],
        insertSpaces = buf.Settings["tabstospaces"],
        trimTrailingWhitespace = true,
        insertFinalNewline = true,
        trimFinalNewlines = true
    }

    if #selectedRanges == 0 then
        local client = findClientWithCapability("documentFormattingProvider", "formatting")
        if client ~= nil then
            client:request("textDocument/formatting", {
                textDocument = client:textDocumentIdentifier(buf),
                options = formatOptions
            })
        end
    else
        local client = findClientWithCapability("documentRangeFormattingProvider", "formatting selections")
        if client ~= nil then
            client:request("textDocument/rangeFormatting", {
                textDocument = client:textDocumentIdentifier(buf),
                range = selectedRanges[1],
                options = formatOptions
            })
        end
    end
end

function completionAction(bufpane)
    local client = findClientWithCapability("completionProvider", "completion")
    if client ~= nil then
        local buf = bufpane.Buf
        local cursor = buf:GetActiveCursor()
        client:request("textDocument/completion", {
            textDocument = client:textDocumentIdentifier(buf),
            position = { line = cursor.Y, character = cursor.X },
            context = {
                -- 1 = Invoked, 2 = TriggerCharacter, 3 = TriggerForIncompleteCompletions
                triggerKind = 1,
            }
        })
    end
end

function gotoAction(kind)
    local cap = string.format("%sProvider", kind)
    local requestMethod = string.format("textDocument/%s", kind)

    return function(bufpane)
        local client = findClientWithCapability(cap, requestMethod)
        if client ~= nil then
            local buf = bufpane.Buf
            local cursor = buf:GetActiveCursor()
            client:request(requestMethod, {
                textDocument = client:textDocumentIdentifier(buf),
                position = { line = cursor.Y, character = cursor.X }
            })
        end
    end
end

function findReferencesAction(bufpane)
    local client = findClientWithCapability("referencesProvider", "finding references")
    if client ~= nil then
        local buf = bufpane.Buf
        local cursor = buf:GetActiveCursor()
        client:request("textDocument/references", {
            textDocument = client:textDocumentIdentifier(buf),
            position = { line = cursor.Y, character = cursor.X },
            context = { includeDeclaration = true }
        })
    end
end

function documentSymbolsAction(bufpane)
    local client = findClientWithCapability("documentSymbolProvider", "document symbols")
    if client ~= nil then
        local buf = bufpane.Buf
        client:request("textDocument/documentSymbol", {
            textDocument = client:textDocumentIdentifier(buf)
        })
    end
end

function openDiagnosticBufferAction(bufpane)
    local buf = bufpane.Buf
    local cursor = buf:GetActiveCursor()
    local filePath = buf.AbsPath
    local found = false

    for _, client in pairs(activeConnections) do
        local diagnostics = client.openFiles[filePath].diagnostics
        for idx, diagnostic in pairs(diagnostics) do
            local startLoc, endLoc = LSPRange.toLocs(diagnostic.range)
            if cursor.Loc.Y == startLoc.Y then
                found = true
                local bufContents = string.format(
                    "%s %s\nhref: %s\nseverity: %s\n\n%s",
                    diagnostic.source or client.serverName or client.clientId,
                    diagnostic.code or "(no error code)",
                    diagnostic.codeDescription and diagnostic.codeDescription.href or "-",
                    diagnostic.severity and severityToString(diagnostic.severity) or "-",
                    diagnostic.message
                )
                local bufTitle = string.format("%s diagnostics #%d", client.clientId, idx)
                local newBuffer = buffer.NewBuffer(bufContents, bufTitle)
                newBuffer.Type.Readonly = true
                local height = bufpane:GetView().Height
                local newpane = micro.CurPane():HSplitBuf(newBuffer)
                if height > 16 then
                    bufpane:ResizePane(height - 8)
                end
            end
        end
    end
    if not found then
        infobar("found no diagnostics on current line")
    end
end


-- EVENTS (LUA CALLBACKS)
-- https://github.com/zyedidia/micro/blob/master/runtime/help/plugins.md#lua-callbacks

function onStdout(text, userargs)
    local clientId = userargs[1]
    log("<-(", clientId, "[stdout] )", text, "\n\n")
    local client = allConnections[clientId]
    client:onStdout(text)
end

function onStderr(text, userargs)
    local clientId = userargs[1]
    -- log("<-(", clientId, "[stderr] )", text, "\n\n")
    local client = allConnections[clientId]
    client.stderr = client.stderr .. text
end

function onExit(text, userargs)
    local clientId = userargs[1]
    activeConnections[clientId] = nil
    allConnections[clientId] = nil
    log(clientId, "exited")
    infobar(clientId .. " exited")
end

function onBufferOpen(buf)
    if buf.Type.Kind ~= buffer.BTDefault then return end
    if buf:FileType() == "unknown" then return end


    local filePath = buf.AbsPath

    if docBuffers[filePath] == nil then
        docBuffers[filePath] = { buf }
    else
        table.insert(docBuffers[filePath], buf)
    end

    for _, client in pairs(activeConnections) do
        client:didOpen(buf)
    end

    local autostarts = settings.autostart[buf:FileType()]
    if autostarts ~= nil then
        for _, server in ipairs(autostarts) do
            local clientId = server.shortName or server.cmd
            if allConnections[clientId] == nil then
                LSPClient:initialize(server)
            end
        end
    end
end

function onQuit(bufpane)
    local closedBuf = bufpane.Buf
    if closedBuf.Type.Kind ~= buffer.BTDefault then return end

    local filePath = closedBuf.AbsPath
    if docBuffers[filePath] == nil then
        return
    elseif #docBuffers[filePath] > 1 then
        -- there are still other buffers with the same file open
        local remainingBuffers = {}
        for _, buf in ipairs(docBuffers[filePath]) do
            if buf ~= closedBuf then
                table.insert(remainingBuffers, buf)
            end
        end
        docBuffers[filePath] = remainingBuffers
    else
        -- this was the last buffer in which this particular file was open
        docBuffers[filePath] = nil

        for _, client in pairs(activeConnections) do
            client:didClose(closedBuf)
        end
    end

end

function onSave(bufpane)
    for _, client in pairs(activeConnections) do
        client:didSave(bufpane.Buf)
    end
end

function preAutocomplete(bufpane)
    -- use micro's own autocompleter if there is no LSP connection
    if next(activeConnections) == nil then return end
    if not settings.tabAutocomplete then return end
    if findClientWithCapability("completionProvider") == nil then return end

    -- "[µlsp] no autocompletions" message can be confusing if it does
    -- not get cleared before falling back to micro's own completion
    bufpane:ClearInfo()

    local cursor = bufpane.Buf:GetActiveCursor()

    -- don't autocomplete at the beginning of the line because you
    -- often want tab to mean indentation there!
    if cursor.X == 0 then return end

    -- if last auto completion happened on the same line then don't
    -- do completionAction again (because updating the completions
    -- would mess up tabbing through the suggestions)
    -- FIXME: invent a better heuristic than line number for this
    if lastAutocompletion == cursor.Y then return end

    local charBeforeCursor = util.RuneStr(cursor:RuneUnder(cursor.X-1))

    if charBeforeCursor:match("%S") then
        -- make sure there are at least two empty suggestions to capture
        -- the autocompletion event – otherwise micro inserts '\t' before
        -- the language server has a chance to reply with suggestions
        setCompletions({"", ""})

        completionAction(bufpane)
        lastAutocompletion = cursor.Y
    end
end

-- Prevent inserting tab when autocompletions are being requested
function preInsertTab(bufpane)
    if next(activeConnections) == nil then return true end
    if not settings.tabAutocomplete then return true end

    local cursor = bufpane.Buf:GetActiveCursor()
    return lastAutocompletion ~= cursor.Y
end

-- FIXME: figure out how to disable all this garbage when there are no active connections

function onBeforeTextEvent(buf, tevent)
    if next(activeConnections) == nil then return end

    local changes = {}
    for _, delta in userdataIterator(tevent.Deltas) do
        table.insert(
            changes,
            {
                range = LSPRange.fromDelta(delta),
                text = util.String(delta.Text)
            }
        )
    end

    for _, client in pairs(activeConnections) do
    	client:didChange(buf, changes)
    end
end

function fullyUpdate(buf)
    if next(activeConnections) == nil then return end

    clearAutocomplete()
    -- filetype is "unknown" for the command prompt
    if buf:FileType() == "unknown" then
        return
    end

    local changes = {
        { text = util.String(buf:Bytes()) }
    }
    for _, client in pairs(activeConnections) do
        client:didChange(buf, changes)
    end
end

function contentUpdate(bp) fullyUpdate(bp.Buf) end

function onCursorUp(bufpane)       clearAutocomplete() end
function onCursorDown(bufpane)     clearAutocomplete() end
function onCursorPageUp(bufpane)   clearAutocomplete() end
function onCursorPageDown(bufpane) clearAutocomplete() end
function onCursorLeft(bufpane)     clearAutocomplete() end
function onCursorRight(bufpane)    clearAutocomplete() end
function onCursorStart(bufpane)    clearAutocomplete() end
function onCursorEnd(bufpane)      clearAutocomplete() end

local TEXT_EVENT = {INSERT = 1, REMOVE = -1, REPLACE = 0}
local UNDO_THRESHOLD = 1000

-- Emulates Micro's Undo() in `internal/buffer/eventhandler.go`
function preUndo(bp)
    if next(activeConnections) == nil then return true end

    local tevents = {}
    local stack = bp.Buf.UndoStack
    local elem = stack.Top
    if not elem or not elem.Value then return true end

    local tev = elem.Value
    local startTime = tev.Time:UnixNano() / go_time.Millisecond
    local endTime = startTime - (startTime % UNDO_THRESHOLD)
    for _ = 0, stack:Len() do
        tev = elem.Value
        if (tev.Time:UnixNano() / go_time.Millisecond) < endTime then break end
        table.insert(tevents, tev)
        elem = elem.Next
        if not elem then break end
    end

    local changes = {}
    for _, tevent in pairs(tevents) do
        local deltaText = nil
        if tevent.EventType == TEXT_EVENT.INSERT then deltaText = "" end

        for _, delta in userdataIterator(tevent.Deltas) do
            -- didChange in "insert mode" start and end should be the same in the json message!
            if deltaText == nil then delta.End = -delta.Start end
            table.insert(changes, {
                range = LSPRange.fromDelta(delta),
                text = deltaText or util.String(delta.Text)
            })
        end
    end

    for _, client in pairs(activeConnections) do
        client:didChange(bp.Buf, changes)
    end
    return true
end

-- Emulates Micro's Redo() in `internal/buffer/eventhandler.go`
function preRedo(bp)
    if next(activeConnections) == nil then return true end

    local tevents = {}
    local stack = bp.Buf.RedoStack
    local elem = stack.Top
    if not elem or not elem.Value then return true end

    local tev = elem.Value
    local startTime = tev.Time:UnixNano() / go_time.Millisecond
    local endTime = startTime - (startTime % UNDO_THRESHOLD) + UNDO_THRESHOLD
    for _ = 0, stack:Len() do
        tev = elem.Value
        if (tev.Time:UnixNano() / go_time.Millisecond) > endTime then break end
        table.insert(tevents, tev)
        elem = elem.Next
        if not elem then break end
    end

    local changes = {}
    for _, tevent in pairs(tevents) do
        local deltaText = nil
        if tevent.EventType == TEXT_EVENT.INSERT then deltaText = "" end

        for _, delta in userdataIterator(tevent.Deltas) do
            -- didChange in "insert mode" start and end should be the same in the json message
            if deltaText == nil then delta.End = -delta.Start end
            table.insert(changes, {
                range = LSPRange.fromDelta(delta),
                text = deltaText or util.String(delta.Text)
            })
        end
    end

    for _, client in pairs(activeConnections) do
        client:didChange(bp.Buf, changes)
    end
    return true
end



-- HELPER FUNCTIONS

function string.split(str)
    local result = {}
    for x in str:gmatch("[^%s]+") do
        table.insert(result, x)
    end
    return result
end

function string.startsWith(str, needle)
	return string.sub(str, 1, #needle) == needle
end

function string.uriDecode(str)
    local function hexToChar(x)
        return string.char(tonumber(x, 16))
    end
    return str:gsub("%%(%x%x)", hexToChar)
end

function string.uriEncode(str)
    local function charToHex(c)
        return string.format("%%%02X", string.byte(c))
    end
    str = str:gsub("([^%w/ _%-.~])", charToHex)
    str = str:gsub(" ", "+")
    return str
end


function table.empty(x)
    return type(x) == "table" and next(x) == nil
end


function editBuf(buf, textedits)
    -- sort edits by start position (earliest first)
    local function sortByRangeStart(texteditA, texteditB)
        local a = texteditA.range.start
        local b = texteditB.range.start
        return a.line < b.line or (a.line == b.line and a.character < b.character)
    end
    -- FIXME: table.sort is not guaranteed to be stable, and the LSP specification
    -- says that if two edits share the same start position the order in the array
    -- should dictate the order, so this is probably bugged in rare edge cases...
    table.sort(textedits, sortByRangeStart)

    local cursor = buf:GetActiveCursor()

    -- maybe there is a nice way to keep multicursors and selections? for now let's
    -- just get rid of them before editing the buffer to avoid weird behavior
    buf:ClearCursors()
    cursor:Deselect(true)

    -- using byte offset seems to be the easiest & most reliable way to keep cursor
    -- position even when lines get added/removed
    local cursorLoc = buffer.Loc(cursor.Loc.X, cursor.Loc.Y)
    local cursorByteOffset = buffer.ByteOffset(cursorLoc, buf)

    local editedBufParts = {}

    local prevEnd = buf:Start()

    for _, textedit in pairs(textedits) do
        local startLoc, endLoc = LSPRange.toLocs(textedit.range)
        if endLoc:GreaterThan(buf:End()) then
            endLoc = buf:End()
        end

        table.insert(editedBufParts, util.String(buf:Substr(prevEnd, startLoc)))
        table.insert(editedBufParts, textedit.newText)
        prevEnd = endLoc

        -- if the cursor is in the middle of a textedit this can move it a bit but it's fiiiine
        -- (I don't think there's a clean way to figure out the right place for it)
        if startLoc:LessThan(cursorLoc) then
            local oldTextLength = buffer.ByteOffset(endLoc, buf) - buffer.ByteOffset(startLoc, buf)
            cursorByteOffset = cursorByteOffset - oldTextLength + textedit.newText:len()
        end
    end

    table.insert(editedBufParts, util.String(buf:Substr(prevEnd, buf:End())))

    buf:Remove(buf:Start(), buf:End())
    buf:Insert(buf:End(), go_strings.Join(editedBufParts, ""))

    local newCursorLoc = buffer.Loc(0, 0):Move(cursorByteOffset, buf)
    buf:GetActiveCursor():GotoLoc(newCursorLoc)

    fullyUpdate(buf)
end

function severityToString(severity)
    local severityTable = {
        [1] = "error",
        [2] = "warning",
        [3] = "information",
        [4] = "hint"
    }
    return severityTable[severity] or "information"
end

function showDiagnostics(buf, owner, diagnostics)

    buf:ClearMessages(owner)

    for _, diagnostic in pairs(diagnostics) do
        local severity = severityToString(diagnostic.severity)

        if settings.showDiagnostics[severity] then
            local extraInfo = nil
            if diagnostic.code ~= nil then
                diagnostic.code = tostring(diagnostic.code)
                if string.startsWith(diagnostic.message, diagnostic.code .. " ") then
                    diagnostic.message = diagnostic.message:sub(2 + #diagnostic.code)
                end
            end
            if diagnostic.source ~= nil and diagnostic.code ~= nil then
                extraInfo = string.format("(%s %s) ", diagnostic.source, diagnostic.code)
            elseif diagnostic.source ~= nil then
                extraInfo = string.format("(%s) ", diagnostic.source)
            elseif diagnostic.code ~= nil then
                extraInfo = string.format("(%s) ", diagnostic.code)
            end

            local lineNumber = diagnostic.range.start.line + 1

            local msgType = buffer.MTInfo
            if severity == "warning" then
                msgType = buffer.MTWarning
            elseif severity == "error" then
                msgType = buffer.MTError
            end

            local startLoc, endLoc = LSPRange.toLocs(diagnostic.range)

            -- prevent underlining empty space at the ends of lines
            -- (fix pylsp being off-by-one with endLoc.X)
            local endLineLength = #buf:Line(endLoc.Y)
            if endLoc.X > endLineLength then
                endLoc = buffer.Loc(endLineLength, endLoc.Y)
            end

            local msg = diagnostic.message
            -- make the msg look better on one line if there's newlines or extra whitespace
            msg = msg:gsub("(%a)\n(%a)", "%1 / %2"):gsub("%s+", " ")
            msg = string.format("[µlsp] %s%s", extraInfo or "", msg)
            buf:AddMessage(buffer.NewMessage(owner, msg, startLoc, endLoc, msgType))
        end
    end
end

function clearAutocomplete()
    lastAutocompletion = -1
end

function setCompletions(completions)
    local buf = micro.CurPane().Buf

    buf.Suggestions = completions
    buf.Completions = completions
    buf.CurSuggestion = -1

    if next(completions) == nil then
        buf.HasSuggestions = false
    else
        buf:CycleAutocomplete(true)
    end
end

function findClientWithCapability(capabilityName, featureDescription)
    if next(activeConnections) == nil then
        infobar("No language server is running! Try starting one with the `lsp` command.")
        return
    end

    for _, client in pairs(activeConnections) do
        if client.serverCapabilities[capabilityName] then
            return client
        end
    end
    if featureDescription ~= nil then
        infobar(string.format("None of the active language server(s) support %s", featureDescription))
    end
    return nil
end

function absPathFromFileUri(uri)
    local match = uri:match("file://(.*)$")
    if match then
        return match:uriDecode()
    else
        return uri
    end
end

function openFileAtLoc(filepath, loc)
    local bp = micro.CurPane()

    -- don't open a new tab if file is already open
    local alreadyOpenPane, tabIdx, paneIdx = findBufPaneByPath(filepath)

    if alreadyOpenPane then
        micro.Tabs():SetActive(tabIdx)
        alreadyOpenPane:tab():SetActive(paneIdx)
        bp = alreadyOpenPane
    else
        local newBuf, err = buffer.NewBufferFromFile(filepath)
        if err ~= nil then
            infobar(err)
            return
        end
        bp:AddTab()
        bp = micro.CurPane()
        bp:OpenBuffer(newBuf)
    end

    bp.Buf:ClearCursors() -- remove multicursors
    local cursor = bp.Buf:GetActiveCursor()
    cursor:Deselect(false) -- clear selection
    cursor:GotoLoc(loc)
    bp.Buf:RelocateCursors() -- make sure cursor is inside the buffer
    bp:Center()
end

-- takes Location[] https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#location
-- and renders them to user
function showLocations(newBufferTitle, lspLocations, labels)
    local bufContents = ""
    for i, lspLoc in ipairs(lspLocations) do
        local fpath = absPathFromFileUri(lspLoc.uri)
        local lineNumber = lspLoc.range.start.line + 1
        local columnNumber = lspLoc.range.start.character + 1
        local line = string.format("%s:%d:%d\n", fpath, lineNumber, columnNumber)
        if labels ~= nil then
            line = labels[i] .. "\t" .. line
        end
        bufContents = bufContents .. line
    end

    local newBuffer = buffer.NewBuffer(bufContents, newBufferTitle)
    newBuffer.Type.Scratch = true
    newBuffer.Type.Readonly = true
    micro.CurPane():HSplitBuf(newBuffer)
end

function findBufPaneByPath(fpath)
    if fpath == nil then return nil end
    for tabIdx, tab in userdataIterator(micro.Tabs().List) do
        for paneIdx, pane in userdataIterator(tab.Panes) do
            -- pane.Buf is nil for panes that are not BufPanes (terminals etc)
            if pane.Buf ~= nil and fpath == pane.Buf.AbsPath then
                -- lua indexing starts from 1 but go is stupid and starts from 0 :/
                return pane, tabIdx - 1, paneIdx - 1
            end
        end
    end
end

function userdataIterator(data)
    local idx = 0
    return function ()
        idx = idx + 1
        local success, item = pcall(function() return data[idx] end)
        if success then return idx, item end
    end
end
