# AGENTS.md — Kingfisher-PhotoSelector 开发约定

> 本文件是给 AI 编程助手（CodeBuddy / WorkBuddy / 其他）看的项目约定。改动代码前先读完本文件。
> 与 README.md 冲突时，以本文件的「纪律类」条目为准；功能描述以 README 为准。

## 项目概述

macOS 原生 SwiftUI 照片筛选软件：批量扫描 RAW 照片，用拉普拉斯方差判定合焦、Apple Vision 识别主体与题材、读取 Canon 对焦点，输出星级建议并写入 Bridge 元数据。仅支持 Apple Silicon (arm64)。

- 技术栈：Swift 5 + SwiftUI + Vision + ImageIO，无第三方依赖（exiftool Perl 已内置打包）
- 构建：`./build.sh` → 产出 `Kingfisher-PhotoSelector.app` + 命令行工具 `kingfisher-photoselector`
- 仓库：`Dyingdong/kingfisher-photo-selector`（main 分支，2026-11-20 由 photography_photo_selection_assistance_software 更名）

## 铁律（违反即事故）

1. **绝不自动执行 git add / commit / push，绝不自动发 Release。** 只有用户明确说「更新」才执行。日常改动只改本地代码 + `./build.sh` 编译验证。
2. **发版流程**（用户说更新后）：`App/Info.plist` 版本号递增（CFBundleShortVersionString / CFBundleVersion）→ `./build.sh` → `ditto -c -k --sequesterRsrc --keepParent` 打包 → zip 命名 `Kingfisher-PhotoSelector-vX-arm64.zip` → `gh release create` 附上包与中文 Release Notes。
3. 不跳过 hook、不顺手重构无关代码、改动最小化。

## 命名规范

- 软件全名 **`Kingfisher-PhotoSelector`**（K 大写，连字符前后**不加空格**）
- App 显示名 / CFBundleName / 可执行名 / 包名统一 `Kingfisher-PhotoSelector`
- 命令行 / 本地文件夹用全小写 kebab-case：`kingfisher-photoselector`
- 发布包 `Kingfisher-PhotoSelector-vX-arm64.zip`；数据目录 `~/Library/Application Support/Kingfisher-PhotoSelector/`；XMP 标记 `[Kingfisher-PhotoSelector]`
- **Bundle ID 保持 `local.workbuddy.photoselector` 不动**（改动会导致 TCC「下载」文件夹授权再次失效）
- README 标题「Kingfisher-一个摄影照片筛选软件」；免责声明后有「名字的由来」章节（只讲翠鸟习性，不解释副名）

## 判定与算法约定

- **每张照片独立判定**，不按批次找基准；固定阈值 `Analyzer.independentFloor = 400`（50 张 Canon 真值标定）
- 灵敏度语义：严格 = 阈值×1.8、标准 = ×1.0、宽松 = ×0.6；拍鸟等小主体建议保持「标准」
- **题材识别与合焦判定/星级是两条独立的线**：改 `FocusSemantics` / `AISubject` / `Score.guessGenre` 不得影响 `Analyze.swift` 的合焦判定与星级
- 对焦点优先读原始 CR3（内置 exiftool）；DNG 仅供参考
- 判定文案用「合焦 / 未合焦」体系，不用「通过 / 失焦」
- 人工圈选只参与单张重判，不改变核心判定阈值

## 题材识别（FocusSemantics / AISubject / Score.guessGenre）

- 三题材（拍鸟/风光/人像）由「对焦点语义 → AI 主体 → 人体/EXIF 兜底」分级判定；**不要调换层级顺序**（已实测评估过，净收益为负）
- 长焦下对焦点 30% 裁块 unknown 且无具体动物标签（≥0.20）时，用 15% 小裁块二次复核（沿用现有鸟标签门槛）；30% 已认出明确风景（nonBird）或具体动物时不复核——兔头部在小裁块会被认成 bird/owl 且动物检测不报，实测踩过坑
- 动物检测（VNRecognizeAnimalsRequest）**必须看具体类别**：检出明确非鸟动物（cat/dog/rabbit/horse…）不判鸟；类别为空/笼统（Animal/Mammal）维持原判
- 长焦下对焦点裁块：多鸟种标签互证可救回置信度边缘的鸟（0.15 + ≥2 标签）；具体动物标签接近鸟标签时（≥鸟×0.6）交回 AI 主体复核
- 深色鸟抠图乱标签时用整图多鸟种标签互证兜底（≥0.10 且 ≥2 标签）
- 花/具体动物识别归「风光」题材，不新增 PhotoGenre 类型
- **文案诚实**：Vision 报什么写什么（兔子被认成猫就写「猫」），绝不臆造物种名；识别不出就如实说，不硬猜
- 「长焦没识别到鸟就按风光」是用户定的规则，勿改回按焦距硬判拍鸟

## 交互红线（用户明确要求过，勿改回）

- 信息区**无折叠**：不要加 DisclosureGroup
- 分隔条：当前是 AppKit 本地事件监听方案（`NSEvent.addLocalMonitorForEvents` + divider 状态），**不要改回 VSplitView**（历史多次失败）
- **人工圈选按照片（URL）持久保留**：`Store.selectionRects: [URL: CGRect]`，切照片/复位缩放不清除；参数按圈选区计算；AI 主体青框独立显示
- 手势分工：⌘+拖框/右键拖框/双击=放大（只看，不碰判定参数）；⌃+拖框=圈选重判；滚轮以光标为锚；单击=复位
- 双击对焦点放大 fill=0.38；悬停提示用**系统 popover**（勿改回自绘 overlay），满 1 秒弹出
- 顶部工具栏 H/F/G/D 四个开关直接显示快捷键小灰字（ShortcutToggleLabel）
- 文案统一「人工圈选」表述（不是「你圈选」）

## 已知边界（如实告知用户，勿硬修）

- 人被道具大面积遮挡时 Vision 全部检测失效（如舞龙），手动改题材
- 花的识别依赖多标签互证（置信度 6~10%），不是硬识别
- 兔子会被 Vision 认成「猫」——这是模型局限，代码按「非鸟动物」处理

## 构建与测试

- 编译：`./build.sh`（exit 0、无 warning 为过）；修改后必须编译验证
- 验证用**真实原始照片**实测引擎（探针参考 `Tests/vision_probe_real.swift`、`Tests/score_probe_real.swift`），不要用带 UI 的截图喂识别器
- `Tools/verify.py`：truth / drift / degrade / bytes 四个子命令做真值复核
- 识别改动要跑回归：题材样本（拍鸟/人像/风光）改前改后对比，零误伤才算过

## 文档

- 功能行为变化时同步更新 README.md（功能表、原理章节、边界说明），描述与代码一致、不夸大
- 本文件（AGENTS.md）：发现新的项目约定时**同步追加更新**
