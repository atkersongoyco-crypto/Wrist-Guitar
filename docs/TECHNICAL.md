# 技术与构建说明

面向 Apple Watch Series 10 的原生 SwiftUI 应用。在 iPhone 导入录音后，应用会把歌曲送到手表。原曲以固定音量连续播放。挥腕或点琴弦时，手表从当前位置的录音里带出一层伴奏细节。轻挥和重挥决定这层声音的力度，连挥时上一拨自然衔接，停手后余音渐收。手表另附 20 秒的原创练习曲，供体验尼龙吉他的拨奏音色。

点手表演奏页左上角的「自由弹奏」，选择「演奏手感」，可在「轻松跟弹」和「精准控弦」之间切换。自由弹奏时可以边弹边切换，歌曲从当前进度继续。个人挥幅对两种手感都生效。跟导入的录音时两种手感均可自由掌握重音，独立演奏时「精准控弦」还支持转腕选和弦。

iPhone 资料库的「随手练习」使用可试拨的唱片封面。在「我的歌曲」点曲目可查看详情、手机试听或选择「用手表弹」，长按歌曲也可打开快捷菜单。导入歌曲优先显示文件里的曲名、歌手和封面，缺少封面时用歌名排出艾绿色的唱片封套。

首次进入 iPhone 资料库时，唱片上的提示会等你亲自试拨。左右横划并松手，琴弦会回弹。手机当前没有试听歌曲时会响一声尼龙吉他，试音跟随手机静音设置。完成或跳过后可点「用手表弹」。引导出现时即记住，升级也沿用已有记录，资料库右上角的问号可随时重看。试音素材见 Samples/Guitar/Credits.txt。

手表的自由弹奏页显示曲名、琴弦和播放键。首次开始自由弹奏时会提示挥腕。手表确认一次演奏后，蓝弦会弹起，再以艾绿色余波收住。点歌名可以换曲。

歌曲卡片和详情显示当前进度。需要转换时会显示「手表音频合成中」，说明 iPhone 正在准备较小的音频副本。可直接发送或已有副本时会跳过这一步。发送期间显示系统提供的传输进度，手表确认选曲后显示「手表已就绪」。手动制作伴奏时会单独显示「伴奏合成中」和制作百分比。

## 已实现的玩法

### 双端体感音游

在 iPhone 资料库点「体感音游」，或从歌曲详情点「开始体感音游」。选择「手表挥腕」，保持两端 Wrist Guitar 打开，再选择 iPhone 或 Apple Watch 播放。本局原曲和触弦音效由所选设备播放。选 iPhone 时，歌曲留在手机即可。选手表时，内置练习可直接玩，自己的歌曲需要先送到手表。也可以选「点屏练习」，在一台 iPhone 上走完整局。

手机从选定版本的音频中分析整首歌的起音和局部节拍，缓存生成的谱面。休止段保留空白，拍点不稳定时优先采用可测到的重音。内置练习沿用录音的 96 BPM。倒数结束后，看音符落到蓝线时挥腕。每次有效挥腕都会触发短促、柔和的击弦音和屏幕回弹。贴拍获得得分和连击，完整打完后保存本机最高分与最高连击。每首歌的原曲、伴奏版，以及手表挥腕与点屏练习分别保留纪录。

两端联机开局前会确认就绪、比对各自的单调时钟。手表回传动作采集时间和序号，表端播放时另回传音频位置。断开连接、歌曲缺失或系统打断时，界面会结束或取消本轮并给出提示。手表触感与动作校准沿用现有设置。

| 操作 | 效果 |
| --- | --- |
| 在 iPhone 导入音频 | 单首导入后自动送表，多首导入后可在曲库选歌。支持可读取的 MP3、M4A、WAV、AIFF |
| 在 iPhone 点开曲目并选择「制作伴奏」 | 在本机生成独立的伴奏版。试听原曲和伴奏版后，把选中的版本传到手表 |
| 在其他 App 中选择用 Wrist Guitar 打开音频文件 | 复制到同一个 iPhone 曲库，可试听并传到手表。歌曲网页链接无法作为伴奏导入 |
| 点「用手表弹」 | 后台把选中的原曲或伴奏版送到手表。手表已有此版本时可直接选中。正在演奏时可先收到新歌，当前演奏结束后再切换 |
| 开始内置练习 | 随录音中的和声拨奏。练习曲以 96 BPM 播放 |
| 演奏时转动数码表冠 | 按 5% 调整总音量。在「更多设置 → 声音平衡」可关闭表冠调音量，跟导入的歌曲时可分别调整拨动强度与歌曲音量 |
| 轻挥或轻点 | 跟本地歌曲时，轻拨和重拨有不同的重音。可连续回拨，也可任意留白 |
| 在手表「更多设置」中点「校准轻重手感」 | 放松手腕，轻挥三次，再按自己舒服的幅度重挥三次。在试拨页听琴声、看每一挥的力度，满意后保存。重新校准和取消都允许保留之前的设置 |
| 开关「随演奏微调」 | 默认开启。轻重交替出现后，根据这一轮弹出的力度缓慢微调琴声和拨奏触感。保存的个人手感和动作触发门槛保持稳定 |
| 切换「自动伴奏」 | 自由弹默认随开始播放选中的音乐。演奏中可以关掉、继续弹吉他，再打开会从伴奏暂停处接上。节奏挑战使用主动选择的拍点来源 |
| 打开设置里的「演奏振动」 | 轻拨和重拨分别对应两种系统触感。关闭后仍可听琴声、看试拨力度。鼓点轻震可单独选择 |
| 打开「更多设置」里的「鼓点轻震」 | 自由弹时跟随伴奏主拍，挑战时跟随目标拍。开启后手腕静止时也会得到轻触。鼓点轻震与挑战提示音默认关闭，保留手动设置过的偏好。鼓点轻震受「演奏振动」总开关控制 |
| 跟自己的本地歌 | 每一挥都牵动屏幕上的琴弦。轻挥带出一层伴奏，重挥使这层细节更清楚；唱段或录音空白处依然可以自由拨动 |
| 空场练习或跟外部音乐 | 空场每四挥推进一个和弦，外部音乐用无固定音高的闷音扫弦 |
| 开启节奏挑战 | 跟光点轻挥或点屏幕，休息几拍仍保留完成次数 |
| 选择「精准控弦」 | 跟录音时按动作力度表现轻重，挑战使用精确判定，独立演奏时可转腕选和弦 |
| 双指互点两下 | 已支持的按钮可响应系统手势，需系统设置允许 |

导入文件须非空，单个文件最多 `100 × 1024 × 1024` 字节，界面标为 100 MB。iPhone 会为较大的高码率歌曲准备较小的 AAC 副本，核对时长和声道后再发送，手机曲库保留导入的原文件。如果手表报告 AAC 副本无法解码，再点「用手表弹」会改传原文件。首次文件传输由系统安排。手表可联络时，手机先询问歌曲是否已在表上，命中即可选歌。手机显示就绪表示手表已完成选歌。

制作伴奏保留原文件。立体声处理利用左右声道之差减弱居中的主唱，并保留一部分低频鼓和贝斯；其他居中乐器也可能变弱。单声道或中置占比很高时，应用在短时频谱中比较相似片段，尝试保留反复出现的伴奏。人声偏向一侧、和声很重或配器变化大时，会有残留或乐器损失。缺少可用背景、输出过弱或处理被取消时可继续使用原曲。重复背景思路参见 [Rafii 与 Pardo 的音乐和人声分离研究](https://interactiveaudiolab.github.io/assets/papers/Rafii-Pardo%20-%20Music-Voice%20Separation%20using%20the%20Similarity%20Matrix%20-%20ISMIR%202012.pdf)。

把原唱或伴奏传到表上后，手表根据左右声道的差异与起音提取可跟弹的伴奏细节，按原录音的位置叠回。外放下混时仍保留这层声音。单声道靠录音本身的节奏起音；清唱或缺少伴奏的地方，声音回应会较轻，琴弦和可选触感仍然回应。跟随外部音乐时，原曲由外部播放器播放，手表可以独立发出演奏声。

内置练习的拍点来自其 96 BPM 谱面。自由弹播放其他本地音频时，会分段估计稳定主拍；节奏挑战按当前目标拍来提示。拍点以歌曲或外部点拍的时钟为准，暂停和结束会停止连续提示。

## 先用附带伴奏试一次

手表默认进入「自由弹奏」。点「节奏挑战」可切换到计分玩法。选择本地伴奏，或让 iPhone 播歌后点「听手机外放」。后者只在手表前台申请麦克风，听约 10 秒并在本机估算拍点。戴着连接 iPhone 的耳机时，也可以在手表上跟音乐点四拍。外放切歌、变速或拖动播放进度后需要重新听拍或点拍。

在手表自带的「音乐」里播 Apple Music 时，可切到 Wrist Guitar，跟着歌点四拍再挥腕。此模式请求将吉他声和提示音混入当前播放，具体耳机路由和延迟待 Series 10 实测。仅想跟歌自由弹奏时，在曲库选「跟外部音乐」。系统「正在播放」提供给用户查看和控制播放，无法作为应用获取原曲音频或逐拍拍点的数据源。见 [Apple 的 Now Playing 说明](https://developer.apple.com/documentation/watchkit/adding-a-now-playing-view)。

挑战开始及继续时，先按原曲速度倒数三拍。「轻松跟弹」通常每两拍设一个目标，135 BPM 起改为每四拍。每个目标只记一次，最多可提前或延后 0.30 秒。每次合拍加 100 分，每四次有额外反馈；空拍和拍点以外的动作保留累计。「精准控弦」按精准、合拍、偏早和偏晚判定计分，并统计本地有声段落的漏拍。「演奏振动」和「挑战提示音」可分别开启或关闭，选择会留到下次使用。

手表内置的「随手练习」也放在 iPhone 的初始曲库和 `Samples/Demo-C-Am-F-G-96bpm.wav` 中。它是 20 秒的 4/4 拍原创伴奏，96 BPM。每个和弦持续 2.5 秒，全曲两遍。第一次可以只挥四下，每次听到和弦变化时再挥下一下。切换到导入的录音后，挥腕直接拨动当前音乐。手表只能从外放及手动点拍来源取得节拍，不能读取外部播放器的原曲声轨。

## 运行要求

- Mac 与包含 iOS / watchOS SDK 的完整 Xcode。
- iPhone：iOS 18 或更高版本。
- Apple Watch：watchOS 11 或更高版本；本原型以 Series 10 为目标设备。
- iPhone 与手表已配对，具备可用的开发签名与设备调试连接。

项目已附带 **`AirGuitar.xcodeproj`**。直接用 Xcode 打开即可，本地 `Core` Swift Package 随项目一起提供，没有第三方包需要下载。运行现有工程不需要 XcodeGen。

## 配置签名并安装到设备

1. 用 Xcode 打开 `AirGuitar.xcodeproj`，在 Xcode Settings → Accounts 中登录你的开发账号。
2. 选中项目，在项目级 Build Settings → User-Defined 中，将 **`AIRGUITAR_BUNDLE_ID`** 从占位值 `com.example.AirGuitar` 改成你的唯一标识，例如 `com.yourname.AirGuitar`。
3. 分别选中 **AirGuitarPhone** 与 **AirGuitarWatch** 两个 target，在 Signing & Capabilities 选择**同一个 Team**，并启用 Automatically manage signing。
4. 确认两个实际 Bundle Identifier 分别为你设置的基础标识和基础标识加 `.watchkitapp`。手表的 `WKCompanionAppBundleIdentifier` 会引用同一个基础变量，正常情况下无需单独改 plist。
5. 将 iPhone 连接到 Mac 并完成“信任此电脑”。在设备要求时开启 iPhone 与手表的开发者模式；在 Xcode 的 Devices and Simulators 中确认设备可供开发。
6. 先选择 **AirGuitarPhone** scheme 和你的真实 iPhone，点击 Run 安装手机端。再选择 **AirGuitarWatch** scheme 和与该手机配对的真实手表，点击 Run 安装手表端。
7. 首次运行按需允许动作访问。直接在手表打开内置练习，或从手机曲库传输自己的歌曲。

用 Xcode 的 Signing & Capabilities 分别为两个 target 配置自己的 Team 和标识。

### 安装到配对设备

请使用自己的开发签名同时签署 iPhone App 和内嵌的 Watch App，再从配对 iPhone 安装。

## 实际限制

- **需要真机验证动作和文件传输。** Watch Connectivity 的 `transferFile` 不支持模拟器。模拟器可用屏幕按钮试音，无法代表真实的手臂识别或演奏延迟。
- **手指连续追踪未实现。** 系统“双指互点两下”只作为开始 / 暂停按钮快捷操作，不能输出每根手指的位置、弯曲角度或连续拨弦数据。
- **动作与触感需要真机验证。** 「轻松跟弹」可以由单独的加速度或角速度触发，使用安静时间和冷却期合并同一次挥动。连续噪声、佩戴侧和实际用力仍需在 Series 10 上调参。
- **跟录音弹奏。** 导入的录音按原有时间线播放。挥腕只控制提取的伴奏细节。每次拨动都能重新发力，停手后逐渐释放。静音片段可保留视觉与触感反馈。内置练习使用既定和弦谱和尼龙弦录音，音源与授权见 Samples/Guitar/Credits.txt。
- **放下手腕时查看歌名。** 手表「设置 → 显示与亮度 → 全天候显示 → 显示 App」可为 Wrist Guitar 开启低亮度显示。在「设置 → 通用 → 返回表盘 → Wrist Guitar → 自定义」可选「1 小时后」。亮度和返回表盘的时间由手表控制。见 [Apple 手表显示设置](https://support.apple.com/zh-cn/guide/watch/apd127ec93ac/watchos)。
- **演奏途中回到表盘。** 手表上已经开始播放的本地伴奏可继续播到曲终。进入后台后停止采集挥腕动作，鼓点轻震需在 App 活跃时使用。挑战在屏幕休息时暂停计分，抬腕回到演奏页可从歌曲当前的位置接下一拍。没有在播本地伴奏时，回到表盘会暂停演奏。
- **声音输出由系统音频路由决定。** Series 10 可使用支持的内置扬声器路径或耳机；充电时请使用耳机播放。耳机与蓝牙链路的延迟需要真机评估。参见 [Apple 的音频会话路由说明](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:))。
- 本地文件会复制到手机和手表各自的应用存储中。删除手机文件不会同步删除手表曲库，反之亦然。

## 工程结构与验证

| 路径 | 用途 |
| --- | --- |
| `iOS/` | 文件导入、试听、曲库及传输状态 |
| `Watch/` | 演奏界面、动作采集、伴奏与吉他音频播放、文件接收 |
| `Core/` | 原声拨动力度与音色处理、动作与节拍判定、练习和弦及音色 |
| `Samples/` | 20 秒原创练习伴奏 |
| `Configuration/Watch-Info.plist` | 手表应用元数据与动作访问说明 |
| `project.yml` | 可选的 XcodeGen 工程生成配置 |

2026-11-19 使用 **Xcode 27.2（27B52）** 完成 iPhone 与内嵌 Watch 的设备版 Release 构建。iOS 与 watchOS SDK 均为 27.2，最低部署版本为 iOS 18、watchOS 11。

核心模块已通过 XCTest，覆盖原声拨动的静音、停止后逐样本恢复、立体声相位、轻重力度、安静起手、连续轻扫、回腕防误触、十二调和弦匹配、扫弦音色、轻重混音、按拍提示和挑战计分。另在本机用真实音频文件和模拟传输回执验证了文件与选歌请求乱序、手表端应用重新启动、手动换歌以及删除后的重传。

IPA 已检查 ZIP 校验、手机与手表可执行文件权限、设备平台、版本号及配套应用标识关系。构建使用 `CODE_SIGNING_ALLOWED=NO`，IPA 尚需签名；配对设备安装及 Series 10 真机交互仍待验证。编译与核心测试不能代替真实传感器、音频延迟和文件传输测试。

```sh
# 在项目目录运行独立核心检查
swift run --package-path Core AirGuitarCoreChecks

# 编译核心 Release 配置
swift build --package-path Core -c release

# 用完整 Xcode 执行 XCTest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Core
```

重现未签名设备构建与 IPA 打包：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AirGuitar.xcodeproj -scheme AirGuitarPhone \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

python3 Scripts/package_unsigned_app.py \
  --app build/DerivedData/Build/Products/Release-iphoneos/AirGuitar.app \
  --output build/AirGuitar-unsigned.ipa
```

打包脚本会检查两个应用的标识关系和可执行文件，并保留执行权限；不会替你签名，也不会覆盖已有 IPA。

只在修改 `project.yml` 或新增源文件后需要重新生成工程。如果已安装 XcodeGen，可运行：

```sh
zsh Scripts/generate_project.sh
```

## Apple 官方参考

- [Core Motion：CMMotionManager](https://developer.apple.com/documentation/coremotion/cmmotionmanager)：获取设备运动数据。
- [在 Apple Watch 启用双指互点手势](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap)：watchOS 11 的按钮主操作及手势限制。
- [Watch Connectivity 文件传输](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))：异步传输与真实配对设备要求。
- [设置 watchOS 项目](https://developer.apple.com/documentation/watchos-apps/setting-up-a-watchos-project)：手表应用与配套 iPhone 应用配置。
- [向项目分配开发团队](https://help.apple.com/xcode/mac/current/#/dev23aab79b4)：Xcode 签名与 Team 配置。
