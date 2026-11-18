// scribe-mcp: a read-only Model Context Protocol server over stdio, so Claude Code can list, search and
// import Scribe calls. It compiles from the app's own Model.swift, Search.swift and Export.swift (see build.sh),
// so search ranking, phrase matching, snippets and the exported Markdown are exactly what the app does.
//
// Transport: one JSON-RPC 2.0 message per line on stdin/stdout. Logs go to stderr only.
// Data: ~/Library/Application Support/Scribe/Recordings, re-read on every tool call, never written.

import Foundation

let serverVersion = "1.0.0"

// MARK: - Output

func send(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func log(_ s: String) {
    FileHandle.standardError.write(Data(("scribe-mcp: " + s + "\n").utf8))
}

func json(_ obj: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

struct ToolError: Error { let message: String }

// MARK: - Library access

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f
}()

/// Index reused across calls: `sync` only refolds recordings that changed since the last call.
let searchService = SearchService()

@MainActor
func loadStore() -> RecordingStore { RecordingStore() }

@MainActor
func folderPath(_ id: String?, _ store: RecordingStore) -> String {
    SearchService.folderPath(of: id, in: Dictionary(store.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
}

@MainActor
func summary(_ r: Recording, _ store: RecordingStore) -> [String: Any] {
    [
        "id": r.id,
        "title": r.title,
        "created": isoFormatter.string(from: r.created),
        "duration": formatTime(r.duration),
        "duration_seconds": Int(r.duration.rounded()),
        "language": r.callLanguage.title,
        "folder": folderPath(r.folderID, store),
        "transcripts": r.results.map { $0.provider.rawValue },
    ]
}

/// Full id, or a unique prefix of one (ids are UUIDs, so 8 characters is plenty).
@MainActor
func find(_ raw: String, _ store: RecordingStore) throws -> Recording {
    let id = raw.trimmingCharacters(in: .whitespaces).uppercased()
    guard !id.isEmpty else { throw ToolError(message: "Pass the call id from list_recent_calls or search_calls.") }
    if let r = store.recordings.first(where: { $0.id.uppercased() == id }) { return r }
    let matches = store.recordings.filter { $0.id.uppercased().hasPrefix(id) }
    if matches.count == 1 { return matches[0] }
    if matches.isEmpty { throw ToolError(message: "No call with id \(raw).") }
    throw ToolError(message: "\(matches.count) calls start with \(raw); pass more of the id.")
}

func provider(_ args: [String: Any]) throws -> ProviderKind? {
    guard let raw = args["provider"] as? String, !raw.isEmpty else { return nil }
    guard let p = ProviderKind(rawValue: raw.lowercased()) else {
        throw ToolError(message: "provider must be one of: " + ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))
    }
    return p
}

func limit(_ args: [String: Any], default d: Int, max m: Int) -> Int {
    let n = (args["limit"] as? Int) ?? (args["limit"] as? Double).map { Int($0) } ?? d
    return min(max(n, 1), m)
}

/// The call as the same Markdown document Scribe's export writes, plus a short metadata block for Claude.
@MainActor
func document(_ r: Recording, _ store: RecordingStore, _ args: [String: Any]) throws -> String {
    let all = (args["all_transcripts"] as? Bool) ?? false
    var notes: [String] = []
    let tabs: [TranscriptResult]
    if all {
        tabs = Exporter.chosenTabs(r, .combined).tabs
    } else if let p = try provider(args) {
        let chosen = Exporter.chosenTabs(r, .preferred(p))
        tabs = chosen.tabs
        notes += chosen.warnings
    } else {
        // Best available, in the app's own fallback order: Claude review, Gemini, ElevenLabs, Local.
        tabs = Exporter.fallbackOrder.compactMap { k in r.results.first { $0.provider == k } }.prefix(1).map { $0 }
    }
    if r.results.isEmpty { notes.append("This call has no transcript yet. Transcribe it in Scribe first.") }
    var out = Exporter.document(for: r, tabs: tabs, format: .markdown, folderPath: folderPath(r.folderID, store))
    var meta = "\n---\n\nScribe call id: \(r.id)\nLanguage: \(r.callLanguage.title)\n"
    if r.results.count > 1 && !all {
        meta += "Other transcripts available: "
            + r.results.filter { t in !tabs.contains { $0.id == t.id } }.map { $0.provider.rawValue }.joined(separator: ", ")
            + " (pass provider, or all_transcripts: true)\n"
    }
    for n in notes { meta += "Note: \(n)\n" }
    out += meta
    return out
}

// MARK: - Tools

let providerSchema: [String: Any] = [
    "type": "string", "enum": ProviderKind.allCases.map(\.rawValue),
    "description": "Which transcript to return. Default: the best available (claude, then gemini, elevenlabs, local).",
]

let tools: [[String: Any]] = [
    [
        "name": "list_recent_calls",
        "description": "List the most recent Scribe call recordings, newest first: id, title, date, duration, language, folder and which transcripts exist.",
        "inputSchema": ["type": "object", "properties": [
            "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many calls (default 10)."],
        ]],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "get_latest_call",
        "description": "Import the most recent Scribe call: title, date, duration, folder and the full transcript as Markdown.",
        "inputSchema": ["type": "object", "properties": [
            "provider": providerSchema,
            "all_transcripts": ["type": "boolean", "description": "Return every transcript of the call as sections."],
        ]],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "get_call",
        "description": "Import one Scribe call by id (or a unique id prefix): metadata plus the full transcript as Markdown.",
        "inputSchema": ["type": "object", "required": ["id"], "properties": [
            "id": ["type": "string", "description": "Call id from list_recent_calls, search_calls or list_folders."],
            "provider": providerSchema,
            "all_transcripts": ["type": "boolean", "description": "Return every transcript of the call as sections."],
        ]],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "search_calls",
        "description": "Scribe's global search across call titles, folder names and every transcript. Case and accent insensitive; "
            + "words match anywhere, \"quoted phrases\" match exactly. Returns ranked calls with a snippet around the best match. "
            + "Use get_call with the id to read a whole call.",
        "inputSchema": ["type": "object", "required": ["query"], "properties": [
            "query": ["type": "string", "description": "Words or \"exact phrase\"."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many calls (default 10)."],
        ]],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "list_folders",
        "description": "Show the Scribe library folder tree with call counts. Pass folder_id to list the calls inside one folder "
            + "(\"root\" for calls not in any folder).",
        "inputSchema": ["type": "object", "properties": [
            "folder_id": ["type": "string", "description": "A folder id from this tool, or \"root\"."],
        ]],
        "annotations": ["readOnlyHint": true],
    ],
]

@MainActor
func callTool(_ name: String, _ args: [String: Any]) throws -> String {
    let store = loadStore()
    switch name {
    case "list_recent_calls":
        let n = limit(args, default: 10, max: 100)
        return json([
            "total_calls": store.recordings.count,
            "calls": store.recordings.prefix(n).map { summary($0, store) },
        ])

    case "get_latest_call":
        guard let r = store.recordings.first else { throw ToolError(message: "The Scribe library has no calls yet.") }
        return try document(r, store, args)

    case "get_call":
        return try document(find(args["id"] as? String ?? "", store), store, args)

    case "search_calls":
        let q = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw ToolError(message: "query is empty.") }
        searchService.sync(recordings: store.recordings, folders: store.folders)
        let res = searchService.search(q, limit: limit(args, default: 10, max: 100), snippetLength: 240)
        return json([
            "query": q,
            "total_matches": res.totalMatches,
            "results": res.hits.map { h -> [String: Any] in
                var row: [String: Any] = [
                    "id": h.recordingID,
                    "title": h.title,
                    "created": isoFormatter.string(from: h.created),
                    "folder": h.folderPath,
                    "snippet": h.snippet,
                    "matched_in": h.snippetField == .transcript ? "transcript" : (h.snippetField == .title ? "title" : "folder"),
                    "match_count": h.matchCount,
                ]
                if let p = h.provider { row["transcript"] = p.rawValue }
                if !h.matchingProviders.isEmpty { row["transcripts_matching"] = h.matchingProviders.map(\.rawValue) }
                return row
            },
        ])

    case "list_folders":
        if let fid = args["folder_id"] as? String, !fid.isEmpty {
            let id: String? = fid == "root" ? nil : fid
            if let id, store.folder(id) == nil { throw ToolError(message: "No folder with id \(fid).") }
            return json([
                "folder": folderPath(id, store),
                "subfolders": store.children(of: id).map { ["id": $0.id, "name": $0.name] },
                "calls": store.recordings(in: id).map { summary($0, store) },
            ])
        }
        func tree(_ parent: String?) -> [[String: Any]] {
            store.children(of: parent).map { f in
                var node: [String: Any] = ["id": f.id, "name": f.name, "calls": store.recordings(in: f.id).count]
                let kids = tree(f.id)
                if !kids.isEmpty { node["subfolders"] = kids }
                return node
            }
        }
        return json(["calls_not_in_a_folder": store.recordings(in: nil).count, "folders": tree(nil)])

    default:
        throw ToolError(message: "Unknown tool \(name).")
    }
}

// MARK: - JSON-RPC loop

@MainActor
func handle(_ msg: [String: Any]) {
    let id = msg["id"]
    let method = msg["method"] as? String ?? ""
    func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    func fail(_ code: Int, _ message: String) {
        if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
    }

    switch method {
    case "initialize":
        let params = msg["params"] as? [String: Any] ?? [:]
        reply([
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "scribe", "version": serverVersion],
            "instructions": "Read-only access to the user's Scribe call recordings and transcripts on this Mac. "
                + "Use get_latest_call to import the most recent call, search_calls to find calls by words or \"phrases\", "
                + "and get_call to read one call in full.",
        ])
    case "ping":
        reply([:])
    case "tools/list":
        reply(["tools": tools])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            reply(["content": [["type": "text", "text": try callTool(name, args)]], "isError": false])
        } catch let e as ToolError {
            reply(["content": [["type": "text", "text": e.message]], "isError": true])
        } catch {
            reply(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        if method.hasPrefix("notifications/") { return }   // initialized, cancelled: nothing to answer
        fail(-32601, "Method not found: \(method)")
    }
}

log("ready, reading \(MainActor.assumeIsolated { loadStore().root.path })")
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        continue
    }
    MainActor.assumeIsolated {
        if let batch = obj as? [[String: Any]] { batch.forEach(handle) }
        else if let msg = obj as? [String: Any] { handle(msg) }
    }
}
