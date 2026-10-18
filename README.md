# 片刻 · Moments

电脑优先的照片与回忆整理原型。照片下方常驻输入框，让地点、人物、当时说过的话和细节跟照片一起保存。

## 已有功能

- 照片合集、旅行分组、人物／风景／美食筛选、日期范围和时间排序。
- 就地补充回忆与详细信息，切换记录身份，导出文字。
- 自定义地点标签：新增、改名、补充名称／地图链接／坐标、关联照片。
- 可调整每行照片数量，原图比例显示，中文／英语／德语界面。
- 地图标点、缩放、照片联动和可选先后顺序线。
- 集中管理展开、排列和弹窗动效，支持减少动态效果。

## 本地运行

需要 Python 3.10+；离线检查另外使用 Node.js。没有第三方 Python 依赖。

```sh
python3 scripts/build.py
python3 scripts/serve.py --port 8767
```

在浏览器打开 `http://127.0.0.1:8767`。地图底图需要联网，由 OpenStreetMap 提供；Leaflet 代码已随项目保存。

```sh
python3 scripts/check_privacy.py
python3 -m unittest discover -s tests
node tests/check-model.mjs
node tests/check-motion.mjs
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

当前没有连接 Apple Photos / iCloud、AI 地名核验、多人同步或在线分享。自由输入的地图链接和坐标先作为线索保存。照片记录不等于完整道路轨迹；先后顺序线不表示实际驾驶路线。

回忆试写保存在当前浏览器标签页；自定义地点保存在本浏览器。临时旅行分组仍属于原型状态。关闭标签页前可导出记录。

## 目录

| 目录 | 内容 |
| --- | --- |
| `src/` | 界面、地点管理和动效源码 |
| `scripts/` | 构建、本机预览和提交前检查 |
| `demo/` | 完全虚构的演示资料 |
| `tests/` | 模型、动效和隐私构建检查 |
| `vendor/leaflet/` | Leaflet 1.9.4 与原许可证 |

Leaflet 的版权与许可见 `vendor/leaflet/LICENSE`。OpenStreetMap 地图保留归属标识，使用须遵循其[图块政策](https://operations.osmfoundation.org/policies/tiles/)。
