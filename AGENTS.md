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
- **清晰度结论独立计算**。题材识别和对焦点与主体的重合度不改变 `Analyzer.classify` 的结论。综合评分由 `ScoreEngine` 负责，题材决定各项权重，对焦点与主体的关系可作为评分和解释依据
- 对焦点优先读原始 CR3（内置 exiftool）；DNG 仅供参考
- 判定文案用**主体清晰度体系（六档）**：主体清晰 / 焦点正常 / 主体偏软 / 整片偏软 / 主体拖影 / 景深不足（另有「无法解码」）；不用「通过 / 失焦」，也不用旧「合焦 / 未合焦」体系
- **放行档分两级**：主体定位可信（前景分割/人脸）才判「主体清晰」；显著性区域/中心权重兜底时判「焦点正常」，原因注明主体清晰度仅供参考
- **整片偏软只轻压星级（≤3）**：整片都软时主体未必废（天空小主体记录照），保留与否由用户判断；主体偏软/主体拖影维持 1~2 星硬压；颜色标签按第 38 行五档映射（整片偏软=黄）
- **元数据不写任何关键词**（dc:subject 已停用，2026-11 起）：关键词会干扰用户已有的 Bridge 关键词体系；标签**直接写判定词到 xmp:Label**（2026-11-20 用户拍板，不写英文颜色值）：主体清晰/焦点正常/整片偏软/景深不足/主体偏软/主体拖影、无法解码不打；照片已有标签不覆盖。Bridge 按文本匹配标签名（共 5 槽位）显示颜色，对不上显示白标（映射见 `Verdict.bridgeLabel`，App/测试/文档共用这一处）
- 人工圈选只参与单张重判，不改变核心判定阈值
- **写入备份随照片放同目录**（2026-11-20 用户要求）：`<照片名>.before.xmp` / `.before-rating.xmp` / `.before-desc.xmp`；**已有备份不覆盖**——永远保留第一次写入前的原始状态；「打开写入前备份」按钮打开当前选中照片所在目录
- **「清除本软件标记」只删自己的东西**：说明/Instructions 里含 ownedTags（[合焦质检]、[Kingfisher-PhotoSelector]、旧代标记）的行 + ownedLabels（判定词体系）标签；用户说明/关键词/星级/拒绝/手标一律不动；无标记照片不写文件。开启「导入时自动写说明」时，导入或恢复会话收尾阶段批量写入说明

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

- **判断依据详细数值默认折叠**（2026-11-25 要求）：仅 InfoView 的详细数值网格使用 DisclosureGroup，标题「展开看详细判别依据」。清晰判定、对焦点和失误提示等结论常显
- 分隔条：当前是 AppKit 本地事件监听方案（`NSEvent.addLocalMonitorForEvents` + divider 状态），**不要改回 VSplitView**（历史多次失败）
- **人工圈选按照片（URL）持久保留**：`Store.selectionRects: [URL: CGRect]`，切照片/复位缩放不清除；参数按圈选区计算；AI 主体青框独立显示
- 手势分工：⌘+拖框/右键拖框/双击=放大（只看，不碰判定参数）；⌃+拖框=圈选重判；滚轮以光标为锚；单击=复位
- 双击以鼠标点击位置为中心放大；悬停提示用**系统 popover**（勿改回自绘 overlay），满 1 秒弹出
- 辅助项默认值：九宫格和对角线开启，热力图关闭
- 顶部工具栏 H/F/G/D 四个开关直接显示快捷键小灰字（ShortcutToggleLabel）
- 文案统一「人工圈选」表述（不是「你圈选」）
- **删除照片后选下一张**（2026-11-22 要求）：单删/批量删都选删除位置之后的照片，只移除成功进入废纸篓的记录；失败项保留。撤销仅恢复到空闲的原路径，并恢复删除前的筛片记录。勿改回跳第一张
- **会话缓存勿删**（2026-11-22 要求，11-23 改存储位置）：Sources/SessionCache.swift 按文件夹保存判定状态（退出/分析完成/重算/删除/改题材时落盘），再打开同文件夹自动加载；缓存文件 = 照片文件夹根目录的 `kingfisher-session.log`（**可见文件**，兼容同目录旧名 `.kingfisher-session.log`）。新旧目录只按所选目录自己的可用会话日志判定，不借用父目录、子目录或软件数据目录日志。题材弹窗点「取消」放弃待导入批次，保持当前会话；「重新分析」= forceReload 跳过缓存；仅接受 v1 至当前版本的会话日志
- 左侧列表多选：`selections: Set<URL>`，⌘/⇧ 行为与访达一致；批量操作针对 selections
- **Shift+方向键边缘滚动**（2026-11-25 要求，仿访达）：仅区间多选路径启用——选中到列表可视边缘（差 1 行）才自动滚动，滚动长度 = **当前列表可视高度的一半**对应的行数（`GeometryReader` 可视高度 ÷ 当前档行高，首帧回退到 ResultRow 上报行数；窗口越高一次露得越多），`scrollTo(target, anchor: .bottom/.top)`；未到边缘列表**完全不动**；非 Shift 切图保持 anchor=nil 最小滚动；无动画约定不变；可见行由 ResultRow onAppear/onDisappear 上报集合推导 min/max，120ms 防抖，避免滚动循环
- **列表缩略图档位**（2026-11-25 要求）：列表工具栏 −/+ 调整 34/46/64/88 宽四档（默认 46×34，老用户外观不变），行高同步联动，档位存 UserDefaults key `Kingfisher-PhotoSelector.thumbnailScale.v1`；解码统一 192px、SwiftUI 缩放，缓存不按档位分键也绝不串尺寸；无动画，不影响 ⇧ 多选/滚动。可见行的缩略图后台解码完成后独立刷新
- **鸟种识别与退出防卡死**（2026-11-25 修复）：主线程绝不能抢 `BirdSpeciesEngine.loadLock`（`isLoaded`/`isLoading` 只读细粒度状态锁）；`runBirdBatch` 只排队 URL、轮到才置 `birdLoading`，避免几百张同时挂「识别中」；`ensureBird` 所有出口（含失败/换代/超时/看门狗迟到结果）必须恰好回调一次 `onSettled`（BirdSettleBox 一次性；token 与 loading 两条 guard 分开写，各自 settle），鸟种任务 token 全局单调；`willTerminate` 只写已编码快照，不在主线程做 845 张 v2 JSON 编码；`setRating` 的 XMP 写成功回调必须同时 `saveSession()`，使会话及时更新，历史恢复时仍以 XMP 核对评级

## 架构升级约定（2026-11-25「把能放到分析阶段的东西全放到分析阶段」）

- **分析结束后进入筛选**：清晰度、拍摄信息和鸟种批量共用等待页；全部完成后才挂载列表和预览。新照片逐张合并清晰度、预览和拍摄信息，复用 ImageIO 源；对焦点按 16 张批读，按完整路径匹配；信息、星级回填后再保存会话。当前选中照片立即请求原尺寸预览。

- **会话缓存 schema v3**（保留 v2 拍摄信息）：`CachedPhoto` 新增可选信息字段 wb/af/exif/focus/human/ai/rating（六类型已补 Codable，不改判定口径）；`rating != nil` 视为该张信息已算过；**v1 老 log 必须可读**（缺字段解码 nil，按需现算，后台补算后回写当前格式）；version 高于当前的拒载
- **信息全量分析阶段**：首次导入、重算与历史目录的新增照片共用 analyzePhotos；仅旧记录缺失拍摄信息时跑 `startInfoPhase`（WB600px/AF exiftool/EXIF/Focus2048px/Human+AI 共享 1024px，与按需 ensure* 同口径同引擎）；并发限 3、utility QoS、进度并入 done/total + sessionPhase 文案；筛选页等待分析完成；与按需 ensure* 共用 attempted 去重
- **鸟种识别有两条独立入口**：导入有新照片的目录或直接导入 RAW 时，题材弹窗仅在「自动识别题材」或「鸟类摄影」下显示「同时识别鸟种」，每次默认关闭。勾选后仅对本次新导入且最终题材为鸟类摄影的照片批量推理，历史日志在后台优先恢复。筛选时仅在有效题材为鸟类摄影的照片上完成人工圈选才识别单张，包括自动判定为鸟类的照片。导入时是否勾选、该照片是否已经自动识别都不限制圈选重认，人工确认优先。切图、放大和手动改题材不会启动推理。解码与推理使用后台串行队列，连续圈选取消未开始的旧任务，已开始任务用 token 拦截迟到结果。日志和 XMP 在后台按顺序写入。读取日志和批量识别各自维护进度，完成后进入筛选。
- **元数据与 DNG**：RAW（含 CR3）的鸟种/星级/判定/说明写同名标准 XMP 侧车（dc:description / photoshop:Instructions / xmp:Label / xmp:Rating），JPG 内嵌。Adobe DNG Converter 转换时自动读同名侧车并嵌入 DNG，这些字段在 CR3→DNG 后保留；鸟种同时写标准 xmp:Label，`kf:BirdSpecies` 自定义命名空间仅本软件精确更新用、不保证被转换器保留
- **中间层预览**：导入分析循环生成「屏幕自适应分辨率」（主屏逻辑×backingScale，钳 1600~3840）JPEG（质量 0.9）落盘 App Support/Kingfisher-PhotoSelector/PreviewCache/<文件夹路径哈希>/<照片名>-<mtime>-<size>.jpg——**不写照片文件夹、不进 Git**，可整体重建；文件名内嵌 mtime+size 校验，源文件变化自动换名重建；历史恢复走 `backfillMidPreviews` 增量补（已存在跳过）；删除照片同步删内存项与磁盘文件
- **双层显示链（v1.0 结构回归）**：原尺寸 LRU(5) 命中→直接显示；否则显示**本张**中间层（内存 LRU 36，磁盘读回，读盘解码后台小队列）；都没有→占位；原尺寸解码完成后无缝替换；「暂显上一张」/previewSwitching 机制已移除（中间层是同一张照片）；**token/fullPreviewURL/generation 防串图必须保留**；当前选中图优先解码，原尺寸就绪后空闲时逐张低优先级预解选中附近 ±2。连续切图取消未开工的过期请求。预览图就绪、平移和缩放只通知预览区；全量原尺寸前移物理不可行（180MB/张内存、15-20GB 磁盘），预取+中间层是替代方案
- `saveSession` 准入条件用 `analysisCoreActive`（判定核心）而非 processing：信息/鸟种阶段 results 已定型可安全落盘

- 会话照片与排除项使用相对导入根目录的路径。v1/v2 文件名记录仅在来源日志和素材都能唯一匹配时恢复。XMP 各写入入口按侧车路径同步整个读改写过程。已有 XMP 无法读取或解析时终止该张写入；JPG 内嵌与侧车分别合并各自原内容，清除前先备份。标签与星级兼容 XMP 属性和元素两种写法。
- 鸟种只读恢复按根目录在后台建立日志索引，分批刷新界面。人工圈选评分按被评分照片的 URL 查找圈选范围。

- 历史恢复在后台按 XMP 核对人工评级，锐度网格异常时单张重算并保留人工记录。人工评级筛选与「只看需留意」取交集。评后前进默认关闭，仅在当前照片写入成功且用户未切图时前进。参考图独立于列表选区和操作目标。

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
