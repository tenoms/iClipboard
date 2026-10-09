# 内存设计与验证

2026-10-09，在 macOS 13.6 / Apple Silicon / 32 GiB 内存机器上实施并验证。

剪贴板捕获与数据状态现在由应用持有，历史列表只在面板显示期间创建。关闭面板会释放原生列表、行视图和预览，并将 Core Data 中已保存的对象恢复为 fault；搜索、筛选、侧栏和预览弹窗的状态仍属于长期存在的根视图。滚动状态只保存坐标，使用公开的 NSScrollView / NSTableView 接口恢复，不持有列表视图。

设置页首次进入时才创建，访问后保留，以继续保存设置分类、未提交的翻译凭据草稿和验证状态。翻译结果面板及触发面板则推迟到第一次实际选词时创建；停止或禁用翻译不会触发面板创建。这样保留现有使用方式，同时消除从未使用过的界面的启动开销。

数据刷新使用 dictionary 查询，仅获取列表所需的元数据。图片、富文本是否存在通过 object ID 查询判断，不加载其二进制内容；去重只计算最新记录的指纹。数据库模型没有改变，无须迁移历史数据，历史软删除与收藏的原有行为保持一致，包括缺失时间戳的旧记录的收藏计数。

图片使用 ImageIO 直接下采样，源图关闭解码缓存，缩略图最大尺寸仍为 320 像素，输出仍为 JPEG，质量仍为 0.7。解析后的图片和富文本共用 NSCache，设置 8 MiB 的估算成本预算与 48 项数量预算，隐藏面板时主动清空，行离开界面时释放自身预览。NSCache 预算是驱逐策略参数，并不代表整个进程的硬内存上限。捕获队列也增加了 autoreleasepool，并在主线程取得捕获类型快照，避免后台读取可变的 UI 状态。

Combine 筛选订阅改用 `.assign(to: &$filteredEntries)`，消除 Store → 订阅 → Store 的引用环。Core Data 的 viewContext 在主队列执行查询与状态发布，重型图片处理继续位于捕获队列。

| 同数据的启动空闲场景 | 旧版 | 优化后的 Release |
| --- | ---: | ---: |
| Physical footprint | 63.9 MiB | 20.5 MiB |
| 生命周期峰值 | 66.4 MiB | 20.8–21.0 MiB |
| malloc 实际分配 | 23.4 MiB | 约 9.2 MiB |
| malloc 碎片 | 19.2 MiB | 约 3.4 MiB |
| malloc 分配块 | 149,714 | 55,048 |

两次测量都使用同一份现有数据库，共 208 条记录，面板未打开，翻译功能关闭。旧版通过重新启动已安装的 1.4 应用测量，新版由本项目构建为 Release；取样分别在启动后约 10 秒和约 80 秒。footprint 下降约 68%，优化后该场景的 `leaks --noContent` 报告为 0。最终重建并启动后，footprint 仍为 20.5 MiB，峰值为 21.0 MiB，用户记录仍为 208 条。之前已运行约 41 小时的旧进程占用约 165–166 MiB，该数字不能作为启动场景的公平对照。打开界面会增加工作集，系统框架和 malloc 也可能缓存内存，20.5 MiB 不代表所有操作场景的占用上限。

验证共 28 项测试全部通过，其中 10 项针对本次改动：Store 和订阅能释放、轻量查询保留二进制标记与收藏、顺序去重和删除后的去重状态、裁剪与清空保留收藏、原始富文本及文件 URL 复制回写、预览重用与清空后重载、图片方向及缩略尺寸、滚动桥接不持有原生列表、真实 NSPanel 隐藏和重复开关能释放历史列表且恢复滚动与筛选状态、未使用的翻译不创建面板。测试使用临时 SQLite 数据库、独立 UserDefaults suite 和独立命名的剪贴板，不向用户的剪贴板写入测试内容。

测试目标已改为加载真实应用实现的 hosted tests，使用 `@testable import iClipboard`，不再把生产源文件复制编译进测试包。应用在测试启动时继续跳过正常的捕获与全局监听初始化。Debug 与 Release 均构建成功，Release 通过 codesign 验证，并已启动验证。界面自动化服务本次未能启动，窗口生命周期检查由上述原生 NSPanel / NSHostingView 测试完成；没有调用外部翻译服务发送测试请求。

```sh
xcodebuild -quiet -project iClipboard.xcodeproj -scheme iClipboard \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData test

ICLIPBOARD_BUILD_CONFIGURATION=Release ./script/build_and_run.sh --verify
```

项目已有的本地 Run 脚本支持 `ICLIPBOARD_BUILD_CONFIGURATION` 选择 Debug 或 Release，默认仍为 Debug。脚本原本属于 gitignore 中的本地开发配置；本次对它的调整保存在工作目录内。

原始诊断位于 `build/memory-validation/`，包括旧进程、旧版重新启动、新版启动的 vmmap、top、heap 和 leaks 输出。测试结果位于 `build/DerivedData/Logs/Test/*.xcresult`，构建与测试日志位于 `build/memory-*.log`。堆与泄漏扫描使用 `--noContent`。

实现集中在 AppDelegate、WindowManager、ContentView、ClipboardStore、ClipboardRow、ClipboardPreviewCache、ImagePreviewLoader、ListScrollPosition 和 TranslationCoordinator。后续调整视图释放策略时，应继续保持 Store 的独立生命周期，并验证置顶、关闭动画、滚动恢复和隐藏期间的捕获；避免为释放设置页而丢失未提交的草稿。

相关平台依据：[Apple 的内存 footprint 说明](https://developer.apple.com/videos/play/wwdc2021/10180/)、[Combine 订阅生命周期](https://developer.apple.com/documentation/combine/publisher/assign(to:))、[ImageIO 下采样](https://developer.apple.com/videos/play/wwdc2018/416/)。
