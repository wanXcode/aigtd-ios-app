# Chat 重排时间方案

## 背景

当前 Chat 页支持：

- `create_reminder`
- `create_list`
- `summarize_lists`
- `move_reminder`
- `complete_reminder`
- `delete_reminder`

但“改任务时间 / 顺延 / 在未来两周内依次安排”这类需求，本质上不是“移动到清单”，而是“先做排期规划，再按方案执行”。

旧链路的问题：

1. 容易把“改时间”误判成 `move_reminder`
2. 即使 AI 理解了用户是在重排时间，也没有对应的本地执行通道
3. 用户看不到规划结果，就已经进入执行态文案

## 新目标

把重排任务时间改成两阶段：

1. `plan_reschedule`
   AI 先输出结构化重排意图，本地生成明确排期方案，只展示，不改系统数据
2. 用户确认
   用户点击卡片里的“应用这个方案”
3. 本地执行
   按同一份计划逐条更新 Reminders 的 `dueDate`

## 交互原则

- Chat 不再把“改时间”硬塞成 `move_reminder`
- 重排任务时间必须先给出方案
- 方案展示时，卡片状态应为“待确认”
- 只有用户确认后，才真正写入提醒事项

## 结构化 intent

新增：

- `plan_reschedule`

典型 entities：

```json
{
  "phase": "plan",
  "scope": "current_open_items",
  "scope_label": "当前未完成事项",
  "strategy": "spread_within_window",
  "ordering": "sequential",
  "window_days": "14",
  "start_date": "",
  "plan_json": "",
  "source_text": "不，你分析一下，在后面的2周内依次"
}
```

说明：

- `phase=plan` 表示当前只是规划态
- `scope` 描述目标范围，例如：
  - `current_open_items`
  - `overdue_open_items`
  - `list:收集箱`
- `window_days` 描述重排时间窗
- `plan_json` 由本地 planner 补齐，保存每条任务的新时间

## 本地 planner

本地统一用 `ReschedulePlanner` 生成计划，保证：

- 远端结构化结果和本地 fallback 都走同一套排期逻辑
- 卡片展示和最终执行使用同一份 `plan_json`
- 即使远端只给了 scope/strategy/window，也能本地补成完整计划

当前 planner 约束：

- 默认只处理未完成事项
- 默认从明天上午 9 点开始
- 使用 `spread_within_window + sequential`
- 在给定时间窗内均匀摊开任务

## 本地执行

新增：

- `ReminderStoreService.updateReminderDueDate(identifier:dueDate:)`

执行流程：

1. 用户点击“应用这个方案”
2. `phase` 从 `plan` 切到 `apply`
3. Chat 卡片进入 pending 状态
4. 本地逐条更新 reminder 的 `dueDate`
5. 成功后刷新提醒事项列表并更新回执

## UI 行为

规划态卡片：

- 标题：`排了个方案`
- 状态：`待确认`
- 按钮：`应用这个方案`

执行态卡片：

- pending：`正在重排`
- success：`排好了`
- failed：`没排成`

## 提示词规则

模型新增约束：

- 用户说“改时间 / 顺延 / 延后 / 重新排 / 在未来两周内依次安排”时，优先输出 `plan_reschedule`
- 不要把这种请求误输出成 `move_reminder`
- `plan_reschedule` 不修改系统状态，因此 `reply` 可以直接告诉用户“我先排了个方案给你看”

## 后续可扩展

- 支持用户用文字确认“就按这个来”
- 支持自定义工作日优先 / 避开周末
- 支持“每天一条 / 每周两条 / 先重排过期任务”
- 支持方案二次编辑而不是重新整句输入
