import Foundation
import JavaScriptCore
import CoreGraphics

/// The "js" imports. A plain JavaScriptCore context, with no network and no DOM.
/// Web views (`webview_*`) are not supported: they return an error.
///
/// Error codes: -1 missing result, -2 invalid context, -3 invalid string.
nonisolated enum ScriptImports {
    static func link(_ host: SourceHost, to wasm: WasmInstance) {
        func context(_ descriptor: Int32) -> JSContext? {
            if case .js(let context)? = host.value(descriptor) { return context }
            return nil
        }

        wasm.link("js", "context_create", "i()") { call in
            guard let context = JSContext() else { return call.returnI32(-2) }
            call.returnI32(host.add(.js(context)))
        }

        wasm.link("js", "context_eval", "i(iii)") { call in
            guard let context = context(call.i32(0)) else { return call.returnI32(-2) }
            guard let script = call.string(call.i32(1), call.i32(2)) else { return call.returnI32(-3) }
            context.exception = nil
            let value = context.evaluateScript(script)
            guard context.exception == nil, let value, !value.isUndefined else { return call.returnI32(-1) }
            call.returnI32(host.add(string: value.toString() ?? ""))
        }

        // The result is a promise. JavaScriptCore runs the promise jobs before
        // evaluateScript returns, so a promise with no timers is settled after one more call.
        wasm.link("js", "context_eval_async", "i(iii)") { call in
            guard let context = context(call.i32(0)) else { return call.returnI32(-2) }
            guard let script = call.string(call.i32(1), call.i32(2)) else { return call.returnI32(-3) }
            context.exception = nil
            context.evaluateScript("var __komaResult = undefined, __komaDone = false;")
            context.setObject(script, forKeyedSubscript: "__komaScript" as NSString)
            context.evaluateScript("Promise.resolve((0, eval)(__komaScript)).then(v => { __komaResult = v; __komaDone = true; }, e => { __komaDone = true; });")
            context.evaluateScript("0")
            guard context.exception == nil,
                  context.objectForKeyedSubscript("__komaDone")?.toBool() == true,
                  let value = context.objectForKeyedSubscript("__komaResult"), !value.isUndefined
            else { return call.returnI32(-1) }
            call.returnI32(host.add(string: value.toString() ?? ""))
        }

        wasm.link("js", "context_get", "i(iii)") { call in
            guard let context = context(call.i32(0)) else { return call.returnI32(-2) }
            guard let name = call.string(call.i32(1), call.i32(2)) else { return call.returnI32(-3) }
            guard let value = context.objectForKeyedSubscript(name), !value.isUndefined else { return call.returnI32(-1) }
            call.returnI32(host.add(string: value.toString() ?? ""))
        }

        for (name, signature) in [("webview_create", "i()"), ("webview_set_rule_list", "i(iii)"),
                                  ("webview_load", "i(ii)"), ("webview_load_html", "i(iiiii)"),
                                  ("webview_wait_for_load", "i(i)"), ("webview_eval", "i(iii)"),
                                  ("webview_eval_async", "i(iii)"), ("webview_add_user_script", "i(iiiii)"),
                                  ("webview_get_cookies", "i(i)"), ("webview_delete_cookie", "i(iiiiiii)")] {
            wasm.link("js", name, signature) { call in call.returnI32(-2) }
        }
    }
}

/// The "canvas" imports: images and a drawing surface, backed by Core Graphics.
/// Enough for sources that cut a scrambled page into tiles and put them back.
/// Paths and text are not drawn.
///
/// Error codes: -1 invalid context, -2 invalid image pointer, -3 invalid image,
/// -4 invalid source rect, -5 invalid result.
nonisolated enum CanvasImports {
    static func link(_ host: SourceHost, to wasm: WasmInstance) {
        func canvas(_ descriptor: Int32) -> CanvasContext? {
            if case .canvas(let canvas)? = host.value(descriptor) { return canvas }
            return nil
        }
        func hostImage(_ descriptor: Int32) -> HostImage? {
            if case .image(let image)? = host.value(descriptor) { return image }
            return nil
        }
        func image(_ descriptor: Int32) -> CGImage? { hostImage(descriptor)?.cgImage }

        wasm.link("canvas", "new_context", "i(ff)") { call in
            guard let canvas = CanvasContext(width: Int(call.f32(0).rounded()), height: Int(call.f32(1).rounded()))
            else { return call.returnI32(-1) }
            call.returnI32(host.add(.canvas(canvas)))
        }

        wasm.link("canvas", "set_transform", "i(ifffff)") { call in
            guard let canvas = canvas(call.i32(0)) else { return call.returnI32(-1) }
            let context = canvas.context
            // Back to the top-left base transform, then apply the new one.
            let base = CGAffineTransform(translationX: 0, y: CGFloat(canvas.height)).scaledBy(x: 1, y: -1)
            context.concatenate(context.ctm.inverted())
            context.concatenate(base)
            context.translateBy(x: CGFloat(call.f32(1)), y: CGFloat(call.f32(2)))
            context.scaleBy(x: CGFloat(call.f32(3)), y: CGFloat(call.f32(4)))
            context.rotate(by: CGFloat(call.f32(5)))
            call.returnI32(0)
        }

        wasm.link("canvas", "copy_image", "i(iifffffffff)") { call in
            guard let canvas = canvas(call.i32(0)) else { return call.returnI32(-1) }
            guard let source = image(call.i32(1)) else { return call.returnI32(-2) }
            let sourceRect = CGRect(x: CGFloat(call.f32(2)), y: CGFloat(call.f32(3)),
                                    width: CGFloat(call.f32(4)), height: CGFloat(call.f32(5)))
            guard let tile = source.cropping(to: sourceRect.integral) else { return call.returnI32(-4) }
            canvas.draw(tile, in: CGRect(x: CGFloat(call.f32(6)), y: CGFloat(call.f32(7)),
                                         width: CGFloat(call.f32(8)), height: CGFloat(call.f32(9))))
            call.returnI32(0)
        }

        wasm.link("canvas", "draw_image", "i(iiffff)") { call in
            guard let canvas = canvas(call.i32(0)) else { return call.returnI32(-1) }
            guard let source = image(call.i32(1)) else { return call.returnI32(-2) }
            canvas.draw(source, in: CGRect(x: CGFloat(call.f32(2)), y: CGFloat(call.f32(3)),
                                           width: CGFloat(call.f32(4)), height: CGFloat(call.f32(5))))
            call.returnI32(0)
        }

        // Paths and text: accepted, not drawn.
        wasm.link("canvas", "fill", "i(iiffff)") { call in call.returnI32(0) }
        wasm.link("canvas", "stroke", "i(iii)") { call in call.returnI32(0) }
        wasm.link("canvas", "draw_text", "i(iiifffiffff)") { call in call.returnI32(0) }
        wasm.link("canvas", "new_font", "i(ii)") { call in call.returnI32(-10) }
        wasm.link("canvas", "system_font", "i(i)") { call in call.returnI32(-10) }
        wasm.link("canvas", "load_font", "i(ii)") { call in call.returnI32(-11) }

        wasm.link("canvas", "get_image", "i(i)") { call in
            guard let canvas = canvas(call.i32(0)) else { return call.returnI32(-1) }
            guard let result = canvas.context.makeImage() else { return call.returnI32(-5) }
            call.returnI32(host.add(.image(HostImage(cgImage: result))))
        }

        wasm.link("canvas", "new_image", "i(ii)") { call in
            guard let bytes = call.bytes(call.i32(0), call.i32(1)) else { return call.returnI32(-2) }
            call.returnI32(host.add(.image(HostImage(data: Data(bytes)))))
        }

        wasm.link("canvas", "get_image_data", "i(i)") { call in
            guard let source = hostImage(call.i32(0)) else { return call.returnI32(-2) }
            guard let data = source.bytes else { return call.returnI32(-5) }
            call.returnI32(host.add(bytes: [UInt8](data)))
        }

        wasm.link("canvas", "get_image_width", "f(i)") { call in
            call.returnF32(image(call.i32(0)).map { Float($0.width) } ?? 0)
        }

        wasm.link("canvas", "get_image_height", "f(i)") { call in
            call.returnF32(image(call.i32(0)).map { Float($0.height) } ?? 0)
        }
    }
}
