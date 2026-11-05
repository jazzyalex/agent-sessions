import XCTest
@testable import AgentSessions

final class CodexExecScriptTests: XCTestCase {
    func testSingleExecCommand() throws {
        let s = try XCTUnwrap(CodexExecScript.parse(#"text(await tools.exec_command({cmd:"pwd; rg -n 'x' AgentSessions","max_output_tokens":2000}));"#))
        XCTAssertEqual(s.calls.map(\.tool), ["exec_command"])
        XCTAssertEqual(s.calls[0].arguments["cmd"], .string("pwd; rg -n 'x' AgentSessions"))
        XCTAssertEqual(s.calls[0].arguments["max_output_tokens"], .number(2000))
    }

    func testTwoStatementsInSourceOrder() throws {
        let s = try XCTUnwrap(CodexExecScript.parse(#"text(await tools.exec_command({cmd:"a"}));text(await tools.exec_command({cmd:"b \"q\""}));"#))
        XCTAssertEqual(s.calls.map { $0.arguments["cmd"] }, [.string("a"), .string(#"b "q""#)])
    }

    func testPromiseAllWithWorkdir() throws {
        let src = "const r = await Promise.all([\n tools.exec_command({cmd:\"npm cache clean\",\"workdir\":\"/x\"}),\n tools.exec_command({cmd:\"brew cleanup\"})\n]);"
        let s = try XCTUnwrap(CodexExecScript.parse(src))
        XCTAssertEqual(s.calls.count, 2)
        XCTAssertEqual(s.calls[0].arguments["workdir"], .string("/x"))
        XCTAssertEqual(s.calls[1].arguments["cmd"], .string("brew cleanup"))
    }

    func testScriptWithoutToolsReturnsNil() {
        XCTAssertNil(CodexExecScript.parse("text('hi')"))
    }

    func testUnreadableValueKeepsParse() throws {
        let s = try XCTUnwrap(CodexExecScript.parse("tools.exec_command({cmd: `ls ${dir}`})"))
        XCTAssertEqual(s.calls.count, 1)
        XCTAssertEqual(s.calls[0].arguments["cmd"], .string("`ls ${dir}`"))
    }

    func testSingleQuotesTemplateNestedValuesAndSourceRange() throws {
        let src = "x; tools.web__run({q: 'it\\'s', t: `a\\nb`, n: [1, true, null], o: {k: \"v\"}, id: someVar, f: g(1, 2)}); y"
        let s = try XCTUnwrap(CodexExecScript.parse(src))
        let a = s.calls[0].arguments
        XCTAssertEqual(s.calls[0].tool, "web__run")
        XCTAssertEqual(a["q"], .string("it's"))
        XCTAssertEqual(a["t"], .string("a\nb"))
        XCTAssertEqual(a["n"], .array([.number(1), .bool(true), .null]))
        XCTAssertEqual(a["o"], .object(["k": .string("v")]))
        XCTAssertEqual(a["id"], .string("someVar"))
        XCTAssertEqual(a["f"], .string("g(1, 2)"))
        XCTAssertTrue(src[s.calls[0].sourceRange].hasPrefix("tools.web__run({"))
        XCTAssertTrue(src[s.calls[0].sourceRange].hasSuffix("})"))
    }

    func testMcpToolNameWithUnderscores() throws {
        let s = try XCTUnwrap(CodexExecScript.parse(#"await tools.mcp__node_repl__js({code:"1+1"})"#))
        XCTAssertEqual(s.calls.map(\.tool), ["mcp__node_repl__js"])
    }

    func testUnterminatedStringIsTolerated() throws {
        let s = try XCTUnwrap(CodexExecScript.parse(#"tools.exec_command({workdir:"/x", cmd:"abc"#))
        XCTAssertEqual(s.calls.count, 1)
        XCTAssertEqual(s.calls[0].arguments["workdir"], .string("/x"))
        XCTAssertNil(s.calls[0].arguments["cmd"])
    }

    func testUnbalancedBracesDoNotHang() {
        XCTAssertNotNil(CodexExecScript.parse("tools.a({x:[{y:"))
        XCTAssertNotNil(CodexExecScript.parse("tools.a({x:}}}))"))
        XCTAssertNil(CodexExecScript.parse("tools."))
    }

    func testPayloadValueFromJSONObject() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":2,"c":null,"d":["x"]}"#.utf8))
        let v = try XCTUnwrap(ToolPayloadValue(jsonObject: obj))
        XCTAssertEqual(v, .object(["a": .bool(true), "b": .number(2), "c": .null, "d": .array([.string("x")])]))
        XCTAssertEqual(ToolPayloadValue.string("s").stringValue, "s")
        XCTAssertNil(ToolPayloadValue.number(1).stringValue)
    }
}
