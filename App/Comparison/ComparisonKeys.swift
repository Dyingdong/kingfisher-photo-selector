import SwiftUI

enum ComparisonKeyAction: Hashable, Codable {
    case group(Int), candidate(Int), rating(Int, Bool)
    case reject(Bool), trash(Bool), zoom(Int, Bool), pan(Int, Int, Int)
    case selectAll, clearSelection, undo, pin

    static let defaults: [(ComparisonKeyAction, String, ComparisonKey)] = {
        typealias Row = (ComparisonKeyAction, String, ComparisonKey)
        var rows: [Row] = [
            (.group(-1), "上一组", .init(35, "P", .control)),
            (.group(1), "下一组", .init(45, "N", .control)),
            (.candidate(-1), "上一张候选", .init(11, "B", .control)),
            (.candidate(1), "下一张候选", .init(3, "F", .control)),
            (.reject(false), "切换选区／候选的放弃标记", .init(51, "⌫")),
            (.reject(true), "切换基准的放弃标记", .init(51, "⌫", .control)),
            (.trash(false), "删除选区／候选", .init(51, "⌫", .command)),
            (.trash(true), "删除基准", .init(51, "⌫", [.command, .control])),
            (.pin, "设为基准", .init(11, "B")),
            (.selectAll, "全选当前组", .init(0, "A", .command)),
            (.clearSelection, "双图缩放复位并取消选区", .init(53, "Esc")),
            (.undo, "撤销", .init(6, "Z", .command))
        ]
        let zoomTargets: [(Bool, String, NSEvent.ModifierFlags)] = [(false, "候选／选区", []), (true, "基准", .control)]
        for (baseline, title, modifier) in zoomTargets {
            for (steps, code, key, action) in [(1, 24, "=", "放大"), (-1, 27, "−", "缩小"), (0, 29, "0", "复位")] {
                rows.append((.zoom(steps, baseline), "\(title)预览·\(action)", .init(UInt16(code), key, modifier)))
            }
            for (stars, code) in [29, 18, 19, 20, 21, 23].enumerated() {
                let action = stars == 0 ? "取消评级" : "\(stars) 星"
                rows.append((.rating(stars, baseline), "\(title)·\(action)", .init(UInt16(code), String(stars), modifier.union(.command))))
            }
        }
        let panTargets: [(Int, String, NSEvent.ModifierFlags)] = [(1, "候选", []), (0, "基准", .control), (2, "双图", .option)]
        for (side, title, modifier) in panTargets {
            for (dx, dy, code, key, direction) in [
                (0, 1, 13, "W", "下"), (1, 0, 0, "A", "右"),
                (0, -1, 1, "S", "上"), (-1, 0, 2, "D", "左")
            ] {
                rows.append((.pan(side, dx, dy), "\(title)画面向\(direction)移", .init(UInt16(code), key, modifier)))
            }
        }
        return rows
    }()
}

struct ComparisonKey: Codable, Equatable {
    private let code: UInt16
    private let modifiers: UInt
    private let label: String
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(_ code: UInt16, _ label: String, _ flags: NSEvent.ModifierFlags = []) {
        self.code = code == 117 ? 51 : code
        self.label = label
        modifiers = flags.intersection(Self.modifierMask).rawValue
    }

    init?(_ event: NSEvent) {
        let label: String
        switch event.keyCode {
        case 51, 117: label = "⌫"
        case 53: label = "Esc"
        case 36, 76: label = "↩"
        case 48: label = "Tab"
        case 49: label = "空格"
        case 123: label = "←"
        case 124: label = "→"
        case 125: label = "↓"
        case 126: label = "↑"
        default:
            guard let key = event.charactersIgnoringModifiers?.first,
                  !key.isWhitespace, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            label = String(key).uppercased()
        }
        self.init(event.keyCode, label, event.modifierFlags)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code && lhs.modifiers == rhs.modifiers
    }

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return ModifierKey.allCases.filter { flags.contains($0.flag) }.map(\.symbol).joined() + label
    }

    var reserved: Bool {
        (123...126).contains(code) && (modifiers == 0 || modifiers == NSEvent.ModifierFlags.shift.rawValue)
    }

    func matches(_ event: NSEvent) -> Bool {
        code == (event.keyCode == 117 ? 51 : event.keyCode)
            && modifiers == event.modifierFlags.intersection(Self.modifierMask).rawValue
    }
}

struct ComparisonKeyEditor: View {
    let binding: (ComparisonKeyAction) -> ComparisonKey
    let assign: (ComparisonKeyAction, ComparisonKey) -> String?
    let reset: () -> Void
    @State private var recording: ComparisonKeyAction?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("对比筛选快捷键").font(.headline)
            Text("方向键始终可用。⌘ 点击增减选区，⇧ 点击或 ⇧ 左右键连选。")
            Text("预览双击放大、单击复位。⌥ 拖动同步平移，⌘ 拖框放大。")
            if let message { Text(message).foregroundStyle(.red) }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(ComparisonKeyAction.defaults.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.1)
                            Spacer()
                            Button(recording == row.0 ? "按下新组合…" : binding(row.0).display) {
                                recording = row.0
                                message = nil
                            }
                            .frame(minWidth: 96)
                        }
                    }
                }
            }
            .frame(height: 360)
            HStack {
                Button("取消录制") { recording = nil; message = nil }.disabled(recording == nil)
                Spacer()
                Button("恢复默认") { reset(); recording = nil; message = nil }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 470)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let recording else { return event }
                if let key = ComparisonKey(event) {
                    message = assign(recording, key)
                    if message == nil { self.recording = nil }
                }
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
