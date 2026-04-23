import Foundation

@objcMembers
open class XCTestCase: NSObject {
    public override init() {}
}

public enum XCTUnwrapError: Error, CustomStringConvertible {
    case nilValue(String)

    public var description: String {
        switch self {
        case .nilValue(let message):
            return message
        }
    }
}

@inline(__always)
private func failureMessage(_ message: String, defaultMessage: String, file: StaticString, line: UInt) -> String {
    let suffix = message.isEmpty ? defaultMessage : message
    return "\(file):\(line): \(suffix)"
}

public func XCTFail(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) -> Never {
    fatalError(failureMessage(message, defaultMessage: "XCTFail invoked", file: file, line: line))
}

public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        if try expression() == false {
            XCTFail(message, file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

public func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let lhs = try expression1()
        let rhs = try expression2()
        if lhs != rhs {
            let defaultMessage = "XCTAssertEqual failed: \(lhs) is not equal to \(rhs)"
            XCTFail(message.isEmpty ? defaultMessage : message, file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        XCTFail(
            message.isEmpty ? "XCTAssertThrowsError failed: expression did not throw" : message,
            file: file,
            line: line
        )
    } catch {
        errorHandler(error)
    }
}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    let value = try expression()
    guard let value else {
        throw XCTUnwrapError.nilValue(
            failureMessage(message, defaultMessage: "XCTUnwrap failed: value was nil", file: file, line: line)
        )
    }
    return value
}
