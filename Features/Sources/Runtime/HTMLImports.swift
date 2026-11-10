import Foundation
import SwiftSoup

/// The "html" imports: an HTML parser and CSS selectors, backed by SwiftSoup.
///
/// Error codes: -1 invalid descriptor, -2 invalid string, -3 invalid HTML,
/// -4 invalid query, -5 no result, -6 SwiftSoup error.
nonisolated enum HTMLImports {
    // Kind values that the plugin expects from `kind`.
    private static let node: Int32 = 1, textNode: Int32 = 2, dataNode: Int32 = 3, comment: Int32 = 4,
                        element: Int32 = 5, list: Int32 = 6, document: Int32 = 7

    static func link(_ host: SourceHost, to wasm: WasmInstance) {
        func string(_ call: WasmCall, _ index: Int) -> String? {
            call.string(call.i32(index), call.i32(index + 1))
        }
        func nodeValue(_ descriptor: Int32) -> SwiftSoup.Node? {
            if case .node(let node)? = host.value(descriptor) { return node }
            return nil
        }
        func elementValue(_ descriptor: Int32) -> Element? { nodeValue(descriptor) as? Element }
        func elementsValue(_ descriptor: Int32) -> Elements? {
            if case .elements(let elements)? = host.value(descriptor) { return elements }
            return nil
        }
        /// Returns a string result as a new descriptor.
        func returnString(_ call: WasmCall, _ value: String?) {
            guard let value else { return call.returnI32(-5) }
            call.returnI32(host.add(string: value))
        }
        func returnNode(_ call: WasmCall, _ node: SwiftSoup.Node?) {
            guard let node else { return call.returnI32(-5) }
            call.returnI32(host.add(.node(node)))
        }
        /// Runs a SwiftSoup call that can throw, and returns -6 on an error.
        func attempt(_ call: WasmCall, _ body: () throws -> Void) {
            do { try body() } catch { call.returnI32(-6) }
        }

        // MARK: Parse

        wasm.link("html", "parse", "i(iiii)") { call in
            guard let html = string(call, 0) else { return call.returnI32(-2) }
            let base = string(call, 2) ?? ""
            guard let document = try? SwiftSoup.parse(html, base) else { return call.returnI32(-3) }
            call.returnI32(host.add(.node(document)))
        }

        wasm.link("html", "parse_fragment", "i(iiii)") { call in
            guard let html = string(call, 0) else { return call.returnI32(-2) }
            let base = string(call, 2) ?? ""
            guard let document = try? SwiftSoup.parseBodyFragment(html, base) else { return call.returnI32(-3) }
            call.returnI32(host.add(.node(document)))
        }

        wasm.link("html", "escape", "i(ii)") { call in
            guard let text = string(call, 0) else { return call.returnI32(-2) }
            returnString(call, Entities.escape(text))
        }

        wasm.link("html", "unescape", "i(ii)") { call in
            guard let text = string(call, 0) else { return call.returnI32(-2) }
            returnString(call, (try? Entities.unescape(text)) ?? text)
        }

        // MARK: Node info

        wasm.link("html", "kind", "i(i)") { call in
            switch host.value(call.i32(0)) {
            case .node(let node)?:
                switch node {
                case is Document: call.returnI32(document)
                case is Element: call.returnI32(element)
                case is TextNode: call.returnI32(textNode)
                case is DataNode: call.returnI32(dataNode)
                case is Comment: call.returnI32(comment)
                default: call.returnI32(Self.node)
                }
            case .elements?, .nodes?: call.returnI32(list)
            default: call.returnI32(0)
            }
        }

        wasm.link("html", "child_nodes", "i(i)") { call in
            guard let node = nodeValue(call.i32(0)) else { return call.returnI32(-1) }
            call.returnI32(host.add(.nodes(node.getChildNodes())))
        }

        wasm.link("html", "children", "i(i)") { call in
            guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
            call.returnI32(host.add(.elements(element.children())))
        }

        wasm.link("html", "parent", "i(i)") { call in
            guard let node = nodeValue(call.i32(0)) else { return call.returnI32(-1) }
            returnNode(call, node.parent())
        }

        wasm.link("html", "siblings", "i(i)") { call in
            guard let node = nodeValue(call.i32(0)) else { return call.returnI32(-1) }
            if let element = node as? Element {
                call.returnI32(host.add(.elements(element.siblingElements())))
            } else {
                call.returnI32(host.add(.nodes(node.siblingNodes())))
            }
        }

        wasm.link("html", "next", "i(i)") { call in
            guard let node = nodeValue(call.i32(0)) else { return call.returnI32(-1) }
            if let element = node as? Element {
                returnNode(call, try? element.nextElementSibling())
            } else {
                returnNode(call, node.nextSibling())
            }
        }

        wasm.link("html", "previous", "i(i)") { call in
            guard let node = nodeValue(call.i32(0)) else { return call.returnI32(-1) }
            if let element = node as? Element {
                returnNode(call, try? element.previousElementSibling())
            } else {
                returnNode(call, node.previousSibling())
            }
        }

        // MARK: Lists

        wasm.link("html", "size", "i(i)") { call in
            switch host.value(call.i32(0)) {
            case .elements(let elements)?: call.returnI32(Int32(elements.size()))
            case .nodes(let nodes)?: call.returnI32(Int32(nodes.count))
            default: call.returnI32(-1)
            }
        }

        wasm.link("html", "get", "i(ii)") { call in
            let index = Int(call.i32(1))
            switch host.value(call.i32(0)) {
            case .elements(let elements)?:
                guard index >= 0, index < elements.size() else { return call.returnI32(-5) }
                returnNode(call, elements.get(index))
            case .nodes(let nodes)?:
                guard nodes.indices.contains(index) else { return call.returnI32(-5) }
                returnNode(call, nodes[index])
            default: call.returnI32(-1)
            }
        }

        wasm.link("html", "first", "i(i)") { call in
            guard let elements = elementsValue(call.i32(0)) else { return call.returnI32(-1) }
            returnNode(call, elements.first())
        }

        wasm.link("html", "last", "i(i)") { call in
            guard let elements = elementsValue(call.i32(0)) else { return call.returnI32(-1) }
            returnNode(call, elements.last())
        }

        // MARK: Select

        wasm.link("html", "select", "i(iii)") { call in
            guard let query = string(call, 1) else { return call.returnI32(-2) }
            do {
                switch host.value(call.i32(0)) {
                case .node(let node as Element)?: call.returnI32(host.add(.elements(try node.select(query))))
                case .elements(let elements)?: call.returnI32(host.add(.elements(try elements.select(query))))
                default: call.returnI32(-1)
                }
            } catch {
                call.returnI32(-4)
            }
        }

        wasm.link("html", "select_first", "i(iii)") { call in
            guard let query = string(call, 1) else { return call.returnI32(-2) }
            do {
                switch host.value(call.i32(0)) {
                case .node(let node as Element)?: returnNode(call, try node.select(query).first())
                case .elements(let elements)?: returnNode(call, try elements.select(query).first())
                default: call.returnI32(-1)
                }
            } catch {
                call.returnI32(-4)
            }
        }

        // MARK: Text and attributes

        wasm.link("html", "text", "i(i)") { call in
            attempt(call) {
                switch host.value(call.i32(0)) {
                case .node(let element as Element)?: returnString(call, try element.text())
                case .node(let text as TextNode)?: returnString(call, text.text().trimmingCharacters(in: .whitespacesAndNewlines))
                case .node(let data as DataNode)?: returnString(call, data.getWholeData())
                case .node(let comment as Comment)?: returnString(call, comment.getData())
                case .elements(let elements)?: returnString(call, try elements.text())
                case .nodes(let nodes)?: returnString(call, try nodes.map { try Self.text(of: $0) }.joined(separator: " "))
                default: call.returnI32(-1)
                }
            }
        }

        wasm.link("html", "untrimmed_text", "i(i)") { call in
            attempt(call) {
                switch host.value(call.i32(0)) {
                case .node(let element as Element)?: returnString(call, try element.text(trimAndNormaliseWhitespace: false))
                case .node(let text as TextNode)?: returnString(call, text.getWholeText())
                case .node(let data as DataNode)?: returnString(call, data.getWholeData())
                case .elements(let elements)?:
                    returnString(call, try elements.array().map { try $0.text(trimAndNormaliseWhitespace: false) }.joined(separator: " "))
                default: call.returnI32(-1)
                }
            }
        }

        wasm.link("html", "own_text", "i(i)") { call in
            guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
            returnString(call, element.ownText())
        }

        wasm.link("html", "data", "i(i)") { call in
            switch host.value(call.i32(0)) {
            case .node(let element as Element)?: returnString(call, element.data())
            case .node(let data as DataNode)?: returnString(call, data.getWholeData())
            case .elements(let elements)?: returnString(call, elements.array().map { $0.data() }.joined(separator: "\n"))
            default: call.returnI32(-1)
            }
        }

        wasm.link("html", "html", "i(i)") { call in
            attempt(call) {
                switch host.value(call.i32(0)) {
                case .node(let element as Element)?: returnString(call, try element.html())
                case .elements(let elements)?: returnString(call, try elements.html())
                case .node(let node)?: returnString(call, try node.outerHtml())
                default: call.returnI32(-1)
                }
            }
        }

        wasm.link("html", "outer_html", "i(i)") { call in
            attempt(call) {
                switch host.value(call.i32(0)) {
                case .node(let node)?: returnString(call, try node.outerHtml())
                case .elements(let elements)?: returnString(call, try elements.outerHtml())
                default: call.returnI32(-1)
                }
            }
        }

        wasm.link("html", "attr", "i(iii)") { call in
            guard let key = string(call, 1) else { return call.returnI32(-2) }
            attempt(call) {
                switch host.value(call.i32(0)) {
                case .node(let node)?:
                    guard Self.hasAttribute(node, key) else { return call.returnI32(-5) }
                    returnString(call, try node.attr(key))
                case .elements(let elements)?:
                    guard let match = elements.array().first(where: { Self.hasAttribute($0, key) }) else {
                        return call.returnI32(-5)
                    }
                    returnString(call, try match.attr(key))
                default: call.returnI32(-1)
                }
            }
        }

        wasm.link("html", "has_attr", "i(iii)") { call in
            guard let key = string(call, 1) else { return call.returnI32(0) }
            switch host.value(call.i32(0)) {
            case .node(let node)?: call.returnI32(Self.hasAttribute(node, key) ? 1 : 0)
            case .elements(let elements)?: call.returnI32(elements.array().contains { Self.hasAttribute($0, key) } ? 1 : 0)
            default: call.returnI32(0)
            }
        }

        wasm.link("html", "base_uri", "i(i)") { call in
            guard let node = nodeValue(call.i32(0)) else { return call.returnI32(-1) }
            returnString(call, node.getBaseUri())
        }

        wasm.link("html", "id", "i(i)") { call in
            guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
            returnString(call, element.id())
        }

        wasm.link("html", "tag_name", "i(i)") { call in
            guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
            returnString(call, element.tagName())
        }

        wasm.link("html", "class_name", "i(i)") { call in
            guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
            returnString(call, (try? element.className()) ?? "")
        }

        wasm.link("html", "has_class", "i(iii)") { call in
            guard let name = string(call, 1) else { return call.returnI32(0) }
            switch host.value(call.i32(0)) {
            case .node(let element as Element)?: call.returnI32(element.hasClass(name) ? 1 : 0)
            case .elements(let elements)?: call.returnI32(elements.hasClass(name) ? 1 : 0)
            default: call.returnI32(0)
            }
        }

        // MARK: Changes

        func change(_ name: String, _ body: @escaping (Element, String) throws -> Void) {
            wasm.link("html", name, "i(iii)") { call in
                guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
                guard let value = string(call, 1) else { return call.returnI32(-2) }
                attempt(call) {
                    try body(element, value)
                    call.returnI32(0)
                }
            }
        }
        change("remove_attr") { element, key in try element.removeAttr(key) }
        change("set_text") { element, text in try element.text(text) }
        change("set_html") { element, html in try element.html(html) }
        change("prepend") { element, html in try element.prepend(html) }
        change("append") { element, html in try element.append(html) }
        change("add_class") { element, name in try element.addClass(name) }
        change("remove_class") { element, name in try element.removeClass(name) }

        wasm.link("html", "set_attr", "i(iiiii)") { call in
            guard let element = elementValue(call.i32(0)) else { return call.returnI32(-1) }
            guard let key = string(call, 1), let value = string(call, 3) else { return call.returnI32(-2) }
            attempt(call) {
                try element.attr(key, value)
                call.returnI32(0)
            }
        }

        wasm.link("html", "remove", "i(i)") { call in
            attempt(call) {
                switch host.value(call.i32(0)) {
                case .node(let node)?: try node.remove()
                case .elements(let elements)?: try elements.remove()
                default: return call.returnI32(-1)
                }
                call.returnI32(0)
            }
        }
    }

    private static func text(of node: SwiftSoup.Node) throws -> String {
        switch node {
        case let element as Element: try element.text()
        case let text as TextNode: text.text()
        case let data as DataNode: data.getWholeData()
        default: ""
        }
    }

    /// SwiftSoup's hasAttr also accepts "abs:" keys and checks that the URL resolves.
    private static func hasAttribute(_ node: SwiftSoup.Node, _ key: String) -> Bool {
        node.hasAttr(key)
    }
}
