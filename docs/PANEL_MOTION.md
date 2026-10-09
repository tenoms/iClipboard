# 主面板动效

2026-10-09。点按菜单栏剪刀图标，主面板以短促的淡入淡出显示和关闭。

| 参数 | 设置 |
| --- | --- |
| 完整打开 | 120 ms，ease-out |
| 完整关闭 | 80 ms，ease-out |
| 动画属性 | 仅窗口透明度 |
| 窗口位移与内容缩放 | 无 |
| 面板与菜单栏间距 | 0 pt，顶边贴齐屏幕可用区域上缘 |
| 减少动态效果 | 立即显示或关闭 |

`PanelPresentationAnimator` 使用 AppKit 的 `NSAnimationContext` 与窗口 `animator()` 代理，仅更新 `alphaValue`。移除了自定义 NSAnimation 进度驱动、逐帧窗口移动、内容层变换、强制布局和首次显示等待。窗口在打开时一次性定位，显隐过程中尺寸与位置保持稳定。

快速连续点击时，系统从当前透明度反转，时长随剩余透明度距离缩短。每次请求替换回调标识，旧动画的完成回调无法关闭重新打开的面板。零时长的代理赋值同样会中止进行中的动画，使“减少动态效果”可以立即生效。

关闭时先将透明度归零，再隐藏窗口和卸载历史列表及预览，隐藏期间保持透明。原实现隐藏后立即将透明度恢复为 1，形成关闭末尾的透明度回跳，存在窗口合成时闪帧的风险；本次移除了这一恢复操作，重新打开时从透明状态淡入。关闭曲线改为 ease-out，保持 80 ms 时长，使淡出立即响应并平缓收尾。退出动画期间内容继续保留。收起途中置顶会重新打开，置顶后再次点按图标仅激活面板。右键菜单、焦点关闭和附加预览 sheet 的保护延续现有逻辑。

验证：38 项 XCTest 全部通过，含 10 项动效测试，覆盖关闭透明度持续下降、卸载时及隐藏后无回跳、重新打开、快速反转、立即双击、关闭途中置顶、重复开关、减少动态效果及中途打断、焦点保护、窗口几何稳定、无需额外内容层以及动画对象释放。内存测试同时验证真实 NSHostingView 列表释放期间窗口保持透明，并恢复搜索和滚动状态。测试日志为 `build/panel-close-fix-test.log`，结果为 `build/panel-close-fix-tests.xcresult`。

Release 验证使用 `ICLIPBOARD_BUILD_CONFIGURATION=Release ./script/build_and_run.sh --verify`，日志为 `build/panel-close-fix-release.log`。桌面自动化服务无法启动，尚未完成菜单栏点击的画面验收；透明度回跳的修正已通过窗口状态测试验证，实际闪烁是否完全消除仍待画面确认。

相关实现：[WindowManager.swift](../iClipboard/WindowManager.swift)、[PanelPresentationAnimator.swift](../iClipboard/Main/PanelPresentationAnimator.swift)、[PanelPresentationTests.swift](../iClipboardTests/PanelPresentationTests.swift)。

平台依据：[Apple 的 animator() 代理](https://developer.apple.com/documentation/appkit/nsanimatablepropertycontainer/animator())、[NSAnimationContext](https://developer.apple.com/documentation/appkit/nsanimationcontext)。
