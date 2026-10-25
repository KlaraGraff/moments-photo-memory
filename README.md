# 片刻 · Moments

电脑优先的照片与回忆整理原型。照片下方常驻输入框，让地点、人物、当时说过的话和细节跟照片一起保存。

## 已有功能

- 照片合集、旅行分组、人物／风景／美食筛选、日期范围和时间排序。
- 就地补充回忆与详细信息，切换记录身份，导出文字。
- 自定义地点标签：新增、改名、补充名称／地图链接／坐标、关联照片。
- 可调整每行照片数量，原图比例显示，中文／英语／德语界面。
- 地图标点、缩放、照片联动、可选先后顺序线，以及记住偏好的鼠标滚轮反转。
- 地图直接嵌入照片工作区：按当前筛选和合集封面显示，地图选点回到照片，照片滚动时联动；道路规划在同页展开。
- 足迹工作区：全球地图总览、按日期组织的时间线、照片跳转和已有回忆默认展开；地图、时间线与照片共用焦点状态。
- 鼠标与触控板分流，触控板捏合保持原方向；地图按帧连续缩放。浏览器没有标准设备标识，无法明确识别的输入按触控板处理。
- 两点道路规划：驾车／步行／骑行，手动请求、取消与规划结果展示。
- 集中管理展开、排列和弹窗动效，支持减少动态效果。
- 大图库分批显示合集，滚动或点击继续加载；地图选中远处素材时自动显示对应批次。独立视频使用海报，点开后才加载本机原视频。
- Mac 本机照片助手与三语导入入口：系统授权、相册／日期范围、只读元数据、按需预览、取消和重试；导入资料保存在本机浏览器。

## 本地运行

需要 Python 3.10+；离线检查另外使用 Node.js。没有第三方 Python 依赖。

```sh
python3 scripts/build.py
python3 scripts/serve.py --port 8767
```

在浏览器打开 `http://127.0.0.1:8767`。地图底图需要联网，由 OpenStreetMap 提供；Leaflet 代码已随项目保存。道路规划使用 FOSSGIS / OSRM；首次发送坐标前需在页面中明确允许。只有点击规划时才发送选中的两点与出行方式，许可仅留在本标签页内存中。公共路线服务用于轻量原型，遵守[服务使用政策](https://routing.openstreetmap.de/about.html)；不要批量抓取路线。

### 原生 macOS UI smoke suite

原生 SwiftUI 应用的 UI smoke suite 使用独立的 `MomentsUITests` scheme。它通过 `-MomentsUITesting` 启动参数使用临时合成数据存储，不会打开用户的 Moments 数据。先用 XcodeGen 生成项目，然后运行：

```sh
xcodegen generate --spec macos/project.yml
scripts/run-ui-smoke.sh
```

测试截图会导出到仓库外的 `$HOME/Developer/moments-ui-screenshots/<timestamp>`；也可以用 `MOMENTS_UI_SCREENSHOTS=/path/to/output` 指定目录。UI 测试需要 macOS 的辅助功能／自动化权限；CI 只编译 UI 测试目标。

```sh
python3 scripts/check_privacy.py
python3 -m unittest discover -s tests
node tests/check-model.mjs
node tests/check-motion.mjs
node tests/check-wheel.mjs
node tests/check-routing.mjs
node tests/check-road-panel.mjs
node tests/check-product-map.mjs
node tests/check-map-workspace.mjs
node tests/check-library-view.mjs
node tests/check-footprints.mjs
node tests/check-apple-import.mjs
python3 tests/check-apple-bridge.py
python3 tests/check-apple-host.py
```

## 示例与个人资料

仓库内只有人工编写的示例数据和代码生成的几何插图。示例日期、文字、分组和坐标都是虚构的；坐标位于零度经纬线附近，仅用于展示功能。没有旅行原片、EXIF、真实位置、真实行程或私人回忆。

个人资料放在被 Git 忽略的 `private-data/` 目录。需要本地使用时，可参考 `demo/sample-data.json` 的结构准备 `private-data/data.json`，在照片条目中加入本地准备好的 `dataURI`、宽和高，再执行：

```sh
python3 scripts/build.py --private-data private-data/data.json
```

输出始终写入被忽略的 `dist/`。私人构建的页面也包含个人资料，应当仅保留在本机。导出的回忆、截图和备份放入 `exports/` 或 `private-data/`。

`check_privacy.py` 检查允许提交的文件范围、常见凭据、个人媒体及示例结构。每次提交前仍应查看 `git diff --cached`，特别留意新增文字和示例数据。已有忽略规则不能保护被强制加入 Git 的文件。

## 原型边界

Apple Photos 已有 Mac 本机助手和产品内导入流程，尚需用户亲自授权后的真实图库验收；当前检查只使用合成数据，没有读取真实图库。助手通过 PhotoKit 读取系统照片图库，能看到的内容取决于这台 Mac 的 iCloud 同步状态；它不直接登录 iCloud，也不能证明云端全库已同步。Windows 接入、自动增量同步、原片下载、AI 地名核验、多人同步和在线分享尚未提供。自由输入的地图链接和坐标先作为线索保存。照片记录不等于完整道路轨迹；先后顺序线不表示实际驾驶路线。沿道路规划结果也仅代表当前路网的候选走法，不用于证明历史轨迹。服务请求最小间隔 1.1 秒，成功结果只作内存缓存；超时、取消或切换路段会移除过期结果。

macOS 13+、Xcode 命令行工具可构建本机助手：

```sh
python3 scripts/build_apple_helper.py
```

助手输出到被忽略的 `dist/apple-helper/`，配对凭据写入被忽略的 `private-data/apple-connection.local.json`。助手只监听本机回环地址，启动不会扫描图库；照片访问只在用户点选授权后发生。通用演示页不含配对凭据，也不会自动连接助手。个人页面构建可用 `scripts/apple_web.py` 的 `integrate_apple(page, source, connection)` 接入这份本机配置；包含凭据的页面必须保留在被忽略的私人目录。默认不下载云端预览，用户勾选后才为所选范围请求预览。原片不会批量下载。

导入内容保存在当前浏览器的 IndexedDB（本机数据库），按稳定标识合并；重复导入保留已写的补充内容与有效预览。图库 ID 不能用于跨文件夹内容去重。UTC 原时间保留，显示日期按导入时的设备时区换算，拍摄地时区未知；更改设备时区后需重新导入以更新显示。收藏调整和手动分组调整仍沿用原型的临时状态，不是完整同步。请保留原标签页并导出回忆备份。

回忆试写保存在当前浏览器标签页；自定义地点保存在本浏览器。临时旅行分组仍属于原型状态。关闭标签页前可导出记录。

地图通过独立的本机组件嵌入主页面，切换照片不重建地图。组件只接收照片 ID、标题、拍摄时间与坐标，不接收照片内容、输入的回忆或人物记录。消息核对来源窗口、来源地址与随机会话标记；没有主页面传入数据时不加载底图。原有单独地图页保留，但产品内“地点与路线”入口直接展开页内地图。

## 目录

| 目录 | 内容 |
| --- | --- |
| `src/` | 界面、地点管理和动效源码 |
| `scripts/` | 构建、本机预览和提交前检查 |
| `demo/` | 完全虚构的演示资料 |
| `tests/` | 模型、动效和隐私构建检查 |
| `vendor/leaflet/` | Leaflet 1.9.4 与原许可证 |

Leaflet 的版权与许可见 `vendor/leaflet/LICENSE`。OpenStreetMap 地图保留归属标识，使用须遵循其[图块政策](https://operations.osmfoundation.org/policies/tiles/)。

人物归类使用的人脸特征模型来自 OpenCV Zoo 的 SFace（Apache-2.0，作者 Yaoyao Zhong），许可证见 `macos/Sources/Moments/People/SFace-LICENSE.txt`。`SFace.mlpackage` 由 `scripts/convert_sface_coreml.py` 从官方 ONNX 文件转换并做 int8 权重量化，不含任何照片或人脸数据；文件哈希固定在 `scripts/check_privacy.py` 里。
