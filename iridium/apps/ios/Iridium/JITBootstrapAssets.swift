import Foundation
import IridiumRuntime

struct JITBootstrapScriptAsset: Sendable, Equatable {
    let name: String
    let source: String

    var base64EncodedPayload: String {
        Data(source.utf8).base64EncodedString()
    }
}

struct JITBootstrapAssetBundle: Sendable, Equatable {
    let kind: String
    let summary: String
    let baseScript: JITBootstrapScriptAsset
    let extensionScript: JITBootstrapScriptAsset?

    static func recommended(
        kind requestedKind: String?,
        recommendation: JITToolRecommendation?
    ) -> JITBootstrapAssetBundle? {
        let resolvedKind = requestedKind ?? defaultKind(for: recommendation)
        switch resolvedKind {
        case "stikdebug-script":
            return stikDebug
        default:
            return nil
        }
    }

    static func defaultSummary(for kind: String) -> String {
        switch kind {
        case "sidestore-attach":
            return
                "Debugger attach is present, but SideStore has not completed the required debugger-backed executable region bootstrap yet."
        case "trollstore-enable-jit":
            return
                "Private JIT capability is present, but the TrollStore-compatible bootstrap has not completed executable region preparation."
        default:
            return
                "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script."
        }
    }

    static var liveContainerScriptData: Data {
        Data(stikDebug.baseScript.source.utf8)
    }

    private static func defaultKind(for recommendation: JITToolRecommendation?) -> String {
        switch recommendation {
        case .some(.sideStore):
            return "sidestore-attach"
        case .some(.trollStore):
            return "trollstore-enable-jit"
        case .some(.stikDebug), .some(.none), nil:
            return "stikdebug-script"
        }
    }

    private static let stikDebug = JITBootstrapAssetBundle(
        kind: "stikdebug-script",
        summary: defaultSummary(for: "stikdebug-script"),
        baseScript: JITBootstrapScriptAsset(
            name: "IridiumDebuggerBootstrap.js",
            source: #"""
            const IRIDIUM_CMD_DETACH = 0;
            const IRIDIUM_CMD_PREPARE_REGION = 1;
            const IRIDIUM_CMD_INSTALL_EXTENSION = 2;
            const IRIDIUM_BRK_IMMEDIATE = 0xf00d;

            let iridiumThreadID = null;
            let iridiumDetached = false;
            let iridiumPendingStopPacket = null;

            const iridiumCommands = {
                [IRIDIUM_CMD_DETACH]: iridiumDetach,
                [IRIDIUM_CMD_PREPARE_REGION]: iridiumPrepareRegion,
                [IRIDIUM_CMD_INSTALL_EXTENSION]: iridiumInstallExtension
            };

            const iridiumPID = get_pid();
            const iridiumAttachResult = send_command(`vAttach;${iridiumPID.toString(16)}`);
            log(`Iridium helper attached: ${iridiumAttachResult}`);

            while (!iridiumDetached) {
                const stopPacket = iridiumPendingStopPacket !== null
                    ? iridiumTakePendingStopPacket()
                    : send_command(`c`);
                if (typeof stopPacket === 'string' && /^[WX]/.test(stopPacket)) {
                    iridiumDetached = true;
                    continue;
                }
                const stopInfo = iridiumDecodeStopPacket(stopPacket);
                if (!stopInfo) {
                    iridiumResumeUnhandledStop(stopPacket);
                    continue;
                }

                iridiumThreadID = stopInfo.threadID;
                if (!iridiumAdvancePC(stopInfo.pc)) {
                    continue;
                }

                const handler = iridiumCommands[stopInfo.command];
                if (!handler) {
                    log(`Iridium helper ignored unsupported command ${stopInfo.command}`);
                    continue;
                }

                handler(stopInfo);
            }

            function iridiumTakePendingStopPacket() {
                const packet = iridiumPendingStopPacket;
                iridiumPendingStopPacket = null;
                return packet;
            }

            function iridiumDetach() {
                send_command(`D`);
                iridiumDetached = true;
            }

            function iridiumResumeUnhandledStop(packet) {
                if (typeof packet === 'string' && /^[WX]/.test(packet)) {
                    iridiumDetached = true;
                    return;
                }
                const signalMatch = /^T([0-9a-f]{2})/.exec(packet);
                const threadMatch = /thread:([0-9a-f]+);/.exec(packet);
                if (!signalMatch || !threadMatch) {
                    return;
                }

                // Resume with the original signal and keep the stop packet
                // returned by the debugger. A second `c` can otherwise consume
                // that packet before this loop gets a chance to inspect it.
                let response = send_command(
                    `vCont;C${signalMatch[1]}:${threadMatch[1]};c`
                );
                if (iridiumLooksLikeStop(response)) {
                    iridiumPendingStopPacket = response;
                    return;
                }

                // Older debugserver builds may reject vCont. The fallback
                // still preserves a returned stop for the next loop.
                response = send_command(`C${signalMatch[1]}`);
                if (iridiumLooksLikeStop(response)) {
                    iridiumPendingStopPacket = response;
                }
            }

            function iridiumLooksLikeStop(packet) {
                return typeof packet === 'string' && /^[TSWX]/.test(packet);
            }

            function iridiumPrepareRegion(stopInfo) {
                if (stopInfo.length === 0n) {
                    iridiumWriteResult(0n);
                    return;
                }

                let rxAddress = stopInfo.address;
                if (rxAddress === 0n) {
                    const allocated = send_command(`_M${stopInfo.length.toString(16)},rx`);
                    if (!allocated) {
                        log(`Iridium helper failed to allocate RX region`);
                        iridiumWriteResult(0n);
                        return;
                    }
                    rxAddress = BigInt(`0x${allocated}`);
                }

                const prepareResult = prepare_memory_region(rxAddress, stopInfo.length);
                log(`Iridium helper prepared region 0x${rxAddress.toString(16)} (${prepareResult})`);
                iridiumWriteResult(rxAddress);
            }

            function iridiumInstallExtension(stopInfo) {
                const scriptText = iridiumReadASCII(stopInfo.address, stopInfo.length);
                const outcome = runScriptAndCapture(scriptText);
                if (outcome.ok) {
                    log(`Iridium helper installed extension script`);
                    iridiumWriteResult(1n);
                } else {
                    log(`Iridium helper failed to install extension script: ${outcome.name} ${outcome.message}`);
                    iridiumWriteResult(0n);
                }
            }

            function iridiumDecodeStopPacket(packet) {
                const threadMatch = /T[0-9a-f]+thread:([0-9a-f]+);/.exec(packet);
                const pcMatch = /20:([0-9a-f]{16});/.exec(packet);
                const x0Match = /00:([0-9a-f]{16});/.exec(packet);
                const x1Match = /01:([0-9a-f]{16});/.exec(packet);
                const x16Match = /10:([0-9a-f]{16});/.exec(packet);
                if (!threadMatch || !pcMatch || !x0Match || !x1Match || !x16Match) {
                    return null;
                }

                const pc = iridiumLittleEndianToNumber(pcMatch[1]);
                const instruction = send_command(`m${pc.toString(16)},4`);
                if (!instruction) {
                    return null;
                }

                const encoded = iridiumLittleEndianU32(instruction);
                if ((encoded & 0xFFE0001F) >>> 0 !== 0xD4200000) {
                    return null;
                }

                const immediate = (encoded >>> 5) & 0xFFFF;
                if (immediate !== IRIDIUM_BRK_IMMEDIATE) {
                    return null;
                }

                return {
                    threadID: threadMatch[1],
                    pc,
                    address: iridiumLittleEndianToNumber(x0Match[1]),
                    length: iridiumLittleEndianToNumber(x1Match[1]),
                    command: Number(iridiumLittleEndianToNumber(x16Match[1]))
                };
            }

            function iridiumAdvancePC(pc) {
                const nextPC = iridiumNumberToLittleEndian(pc + 4n);
                const response = send_command(`P20=${nextPC};thread:${iridiumThreadID};`);
                return response && response.startsWith(`OK`);
            }

            function iridiumWriteResult(value) {
                const encoded = iridiumNumberToLittleEndian(value);
                send_command(`P0=${encoded};thread:${iridiumThreadID};`);
            }

            function iridiumReadASCII(address, length) {
                if (address === 0n || length === 0n) {
                    return ``;
                }
                const memory = send_command(`m${address.toString(16)},${length.toString(16)}`);
                let text = ``;
                for (let offset = 0; offset < memory.length; offset += 2) {
                    text += String.fromCharCode(parseInt(memory.slice(offset, offset + 2), 16));
                }
                return text;
            }

            function runScriptAndCapture(scriptText) {
                try {
                    return {
                        ok: true,
                        value: eval(scriptText)
                    };
                } catch (error) {
                    return {
                        ok: false,
                        name: error && error.name ? String(error.name) : `Error`,
                        message: error && error.message ? String(error.message) : String(error),
                        stack: error && error.stack ? String(error.stack) : ``
                    };
                }
            }

            function iridiumLittleEndianToNumber(value) {
                const bytes = value.match(/../g) || [];
                let result = 0n;
                for (let index = bytes.length - 1; index >= 0; index -= 1) {
                    result = (result << 8n) | BigInt(parseInt(bytes[index], 16));
                }
                return result;
            }

            function iridiumNumberToLittleEndian(value) {
                const bytes = [];
                let working = BigInt(value);
                for (let index = 0; index < 8; index += 1) {
                    bytes.push(Number(working & 0xFFn).toString(16).padStart(2, '0'));
                    working >>= 8n;
                }
                return bytes.join(``);
            }

            function iridiumLittleEndianU32(value) {
                return parseInt((value.match(/../g) || []).reverse().join(``), 16);
            }
            """#
        ),
        extensionScript: JITBootstrapScriptAsset(
            name: "IridiumDebuggerBootstrapExtension.js",
            source: #"""
            let iridiumDetachAfterFirstBreakpoint = false;

            iridiumCommands[3] = function(stopInfo) {
                iridiumDetachAfterFirstBreakpoint = stopInfo.address !== 0n;
                iridiumWriteResult(1n);
            };

            iridiumCommands[4] = function(stopInfo) {
                if (stopInfo.address === 0n || stopInfo.length === 0n) {
                    iridiumWriteResult(0n);
                    return;
                }
                const hexBytes = send_command(`m${stopInfo.address.toString(16)},${stopInfo.length.toString(16)}`);
                send_command(`M${stopInfo.address.toString(16)},${stopInfo.length.toString(16)}:${hexBytes}`);
                iridiumWriteResult(1n);
                if (iridiumDetachAfterFirstBreakpoint) {
                    iridiumDetach();
                }
            };
            """#
        )
    )
}

enum JITHelperLaunchTool: String, Sendable {
    case stikDebug
    case sideStore
    case trollStore

    var urlSchemes: [String] {
        switch self {
        case .stikDebug:
            ["stikjit", "stikdebug", "livecontainer2"]
        case .sideStore:
            ["sidestore"]
        case .trollStore:
            ["apple-magnifier"]
        }
    }
}

enum JITHelperLaunchURLFactory {
    static func recommendedTool(
        for snapshot: HostCapabilitySnapshot,
        installedSchemes: Set<String>
    ) -> JITHelperLaunchTool? {
        if snapshot.jitSessionKind == .trollStorePrivate {
            return nil
        }

        let available = [JITHelperLaunchTool.stikDebug, .sideStore, .trollStore].filter {
            resolvedScheme(for: $0, installedSchemes: installedSchemes) != nil
        }

        if let recommendation = snapshot.jitToolRecommendation {
            switch recommendation {
            case .stikDebug:
                return available.first(where: { $0 == .stikDebug })
            case .sideStore:
                return available.first(where: { $0 == .sideStore })
            case .trollStore:
                return available.first(where: { $0 == .trollStore })
            case .none:
                break
            }
        }

        return available.first
    }

    static func resolvedScheme(
        for tool: JITHelperLaunchTool,
        installedSchemes: Set<String>
    ) -> String? {
        tool.urlSchemes.first(where: installedSchemes.contains)
    }

    static func launchURL(
        tool: JITHelperLaunchTool,
        bundleIdentifier: String,
        processIdentifier: pid_t,
        installedSchemes: Set<String>,
        bootstrapAssets: JITBootstrapAssetBundle? = nil
    ) -> URL? {
        guard let scheme = resolvedScheme(for: tool, installedSchemes: installedSchemes) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme == "livecontainer2" ? "stikjit" : scheme
        switch tool {
        case .stikDebug:
            var queryItems = [
                URLQueryItem(name: "bundle-id", value: bundleIdentifier),
                URLQueryItem(name: "pid", value: String(processIdentifier)),
            ]
            if let bootstrapAssets, bootstrapAssets.kind == "stikdebug-script" {
                queryItems.append(
                    URLQueryItem(
                        name: "script-data",
                        value: bootstrapAssets.baseScript.base64EncodedPayload
                    )
                )
                queryItems.append(
                    URLQueryItem(name: "script-name", value: bootstrapAssets.baseScript.name)
                )
            }
            components.host = "enable-jit"
            components.queryItems = queryItems
        case .sideStore:
            components.host = "sidejit-enable"
            components.queryItems = [
                URLQueryItem(name: "pid", value: String(processIdentifier))
            ]
        case .trollStore:
            components.host = "enable-jit"
            components.queryItems = [
                URLQueryItem(name: "bundle-id", value: bundleIdentifier)
            ]
        }
        guard scheme == "livecontainer2", let guestURL = components.url else {
            return components.url
        }
        var container = URLComponents()
        container.scheme = "livecontainer2"
        container.host = "open-url"
        container.queryItems = [URLQueryItem(name: "url", value: Data(guestURL.absoluteString.utf8).base64EncodedString())]
        return container.url
    }
}
