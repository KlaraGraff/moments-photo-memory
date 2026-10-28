# Moments 大库后端重构方案

## 证据

- 5,000 条合成库导入本身约 20 秒；导入后的派生任务约 3 分钟，并把主线程占满超过 2 分钟。
- People 页在当前修复后约 6 秒；Map 页从 57 秒降到 16 秒，但仍有 9 秒级停顿。
- Timeline 未能在同一进程进入可报告状态。现有实现让 SwiftUI 页面直接遍历 SwiftData 模型和关系，并在重建时反复解析地点名称。
- Map、Timeline、Library 都各自从 @Query 重新过滤、排序、构建派生数据；没有共享的只读投影或增量索引。

## 目标

把 SwiftData 变成持久化事实源，把页面读取改为不可变的轻量投影：页面不在 body、annotation builder 或重建循环里访问 SwiftData 关系，不重复做地点最近邻、分组、路线和筛选。导入及后台派生工作在后台 context/actor 执行，主线程只接收一次新的投影快照和用户交互结果。

## 设计

1. 在 MomentsCore 增加纯值类型 LibraryPhotoDescriptor、LibraryPlaceDescriptor、LibraryProjection 和 LibraryProjectionBuilder。Builder 接受已脱离 SwiftData 的 DTO，产出按 ID、日期、地点和坐标建立的索引、Timeline 日/月、Map 聚类输入和筛选字段。
2. 在 App 层增加 LibraryProjectionStore（actor）。它从独立 ModelContext 分批读取 SwiftData，复制成 DTO，在后台调用 Core Builder；构建期间继续使用上一份快照，完成后主 actor 一次替换。取消旧 generation，避免连续导入堆积重建任务。
3. 让 Timeline、Map、Chapters 读取同一个 projection。页面只做轻量可见性筛选和 UI 状态更新；地点名、nearest place、日期分组、Map route/cluster 只在 Builder 中做一次。Library 仍需单独迁移：当前实现继续使用 SwiftData 查询，不能把本阶段描述成全屏完成。
4. 把 People、burst、place-name 等后台任务的完成通知合并为一次 projection invalidation，避免每个关系保存都触发整棵 SwiftUI 图重算。
5. 保留现有 SwiftData 模型、迁移和 UI 外观，先不做 schema 迁移；projection 是可丢弃的内存派生数据，启动或变更后可从事实源重建。

## 分包顺序

- P1：MomentsCore 的 DTO、Builder、筛选/地点/日期/空间索引及 Linux 测试。
- P2：App 层 actor store、generation/cancellation、批量读取和通知合并；加入 5k/20k synthetic benchmark。
- P3：Timeline/Map/Chapters 迁移到 projection；最后迁 Library，避免重复触碰同一屏幕文件。
- P4：探针改为记录 projection build、publish 和各页面首帧；重新收集 5k/20k before/after。

## 验收

- swift test --package-path macos/MomentsCore 覆盖 5,000 和 20,000 DTO 的构建、筛选、聚类、日期分组和取消。
- hosted macOS 探针在一个进程内完成所有阶段，报告每阶段 ready、stall、busy、memory 和栈样本。
- UI 外观和用户可编辑数据行为不变；无真实照片、GPS、路径或凭据进入仓库。
