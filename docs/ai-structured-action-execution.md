# AIGTD 结构化 Action 执行方案

## 目标

把当前 Chat 页的执行链路从“AI 先说一句像是成功的话，再由前端猜是否要执行”，改成更可靠的三段式：

1. AI 负责理解用户意图，并返回结构化 action
2. 本地负责校验和执行 Reminders 操作
3. 聊天里展示基于真实执行结果生成的最终回执

这样可以避免以下问题：

- AI 回复里说“已经记上了”，但实际上没有创建任务
- 前端只能靠关键词规则去猜用户是不是想建任务
- 同一条输入在不同模型下表现不稳定
- UI 文案和 Reminders 真实状态不一致

## 当前现状

### 现有执行顺序

当前链路大致是：

1. `ChatHomeView.sendPrompt` 把用户输入发给 `AgentRuntimeService`
2. `AgentRuntimeService` 只让模型输出自然语言正文
3. 远端返回后，客户端把结果封装成 `MockAgentResult(reply: ..., actionType: nil, ...)`
4. 聊天页只有在 `actionType` 非空时，才真正执行 `createReminder / moveReminder / completeReminder`

也就是说，现在远端模型的职责其实只是“说话”，不是“给出可执行动作”。

### 当前问题根因

根因不是模型理解不了意图，而是当前协议没有让模型返回结构化 action：

- prompt 要求模型“只输出给用户看的自然语言回复正文”
- 远端返回被统一收敛成 `actionType = nil`
- 前端只能在远端没有结构化 action 时，用本地规则兜底判断

结果就是：

- 模型可以理解“新建任务，明天整理数据库”是在下指令
- 但当前协议下，它最多只能回一句“好，已经记上了”
- 真正的 Reminders 写入并不会自动发生

## 目标架构

### 新执行顺序

新的主链路应当是：

1. 用户输入
2. AI 返回结构化 action envelope
3. 本地校验 action 是否完整、是否允许执行
4. 本地执行 Reminders 写入或修改
5. 根据真实执行结果生成最终回复
6. 更新聊天消息、结果卡和 Reminders 列表

### 角色边界

#### AI 负责

- 识别用户是否在建任务 / 建清单 / 查看 / 移动 / 完成
- 提取标题、时间、目标清单等参数
- 对模糊输入给出合理结构化解释

#### 本地负责

- 校验 JSON 是否符合协议
- 校验字段是否完整
- 执行 ReminderStoreService
- 生成最终成功 / 失败回执
- 在 AI 不可用或返回异常时做 fallback

### 关键原则

- AI 不应在执行前就承诺“已创建成功”
- 最终回复必须以真实执行结果为准
- 普通聊天不应误触发 Reminders 操作
- 本地规则引擎保留，但只做 fallback，不再做主路径

## 结构化协议

### 远端返回格式

主协议沿用当前代码里已有的 envelope 形态：

```json
{
  "reply": "好的，我来帮你处理这条任务。",
  "summary": "准备创建任务：整理数据库",
  "confidence": 0.93,
  "followUpPrompt": "如果你愿意，我也可以顺手补备注或换清单。",
  "matchedSignals": ["create_reminder", "tomorrow"],
  "action": {
    "intent": "create_reminder",
    "title": "创建任务",
    "entities": {
      "title": "整理数据库",
      "due_date": "2026-04-16T09:00:00+08:00",
      "preferred_list_name": "提醒",
      "note": "",
      "source_text": "新建任务，明天整理数据库"
    },
    "requiresConfirmation": false
  }
}
```

### intent 范围

- `create_reminder`
- `create_list`
- `summarize_lists`
- `capture_message`
- `move_reminder`
- `complete_reminder`
- `fallback`

### 设计约束

- `reply` 是“执行前草稿回复”，不是最终成功回执
- 真正展示给用户的成功 / 失败文案，本地执行后再生成
- `summary` 用于结果卡摘要，不直接等于聊天正文
- `entities` 允许不同 intent 按需扩展，但核心字段应稳定

## UI 与执行策略

### 可执行 action

以下 action 进入本地执行层：

- `create_reminder`
- `create_list`
- `move_reminder`
- `complete_reminder`

处理原则：

- 先创建 `ActionLog`
- 再执行本地 ReminderStoreService
- 执行成功后，更新聊天回复为真实结果
- 执行失败后，更新聊天回复为明确失败原因

### 非执行 action

以下 action 不改系统状态：

- `summarize_lists`
- `capture_message`
- `fallback`

处理原则：

- 直接展示 AI 自然语言回复
- 不创建执行卡
- 不落 Reminders

### 聊天文案原则

#### 执行前

如果需要显示处理中状态，文案应该是：

- `我来帮你记一下。`
- `我来帮你调整这条任务。`
- `我来帮你建这个清单。`

不要在执行前说：

- `已经记好了`
- `已经移好了`
- `已经完成了`

#### 执行成功

应由本地根据真实结果生成，例如：

- `好，已经记上了：整理数据库。时间我放到明天了。`
- `好，这个清单已经建好了：项目复盘。`
- `好，这条已经移到“等待中”了。`
- `好，这条已经标记完成。`

#### 执行失败

应明确告诉用户没成功，例如：

- `我理解的是要新建任务，但这次没有写进提醒事项：提醒事项权限未开启。`
- `我理解的是要移动任务，但没有找到目标列表“等待中”。`

## Fallback 策略

### 保留本地规则，但降级为备用

`MockAgentService` 仍然保留，用于以下场景：

1. 远端模型不可用
2. 远端模型返回纯文本，没有结构化 action
3. 远端模型返回 JSON 结构不合法

### fallback 使用原则

- 优先相信远端结构化 action
- 只有远端不可执行时，才启用本地规则解析
- fallback 一旦执行成功，也应按真实结果更新聊天回执

### 不做的事情

- 不让本地规则长期替代 AI 做主判断
- 不在远端已给出合法 action 时再次用本地规则覆盖

## 实施计划

### 第一阶段

- 调整 `AgentRuntimeService` prompt，要求远端输出结构化 JSON envelope
- 让 `AgentRuntimeService` 能把远端 JSON 解析成 `MockAgentResult(actionType + payloadJSON)`
- 聊天页不再把 AI 自然语言当作最终执行成功文案

### 第二阶段

- `ChatHomeView` 在 action 执行成功 / 失败后，写回最终回复
- 本地结果卡摘要从“准备创建”升级为“已创建 / 已失败”
- 保留 fallback，但只在远端不可执行时触发

### 第三阶段

- 进一步减少对 `MockAgentService` 的依赖
- 把查看类、澄清类、多步操作也统一迁到结构化协议
- 视情况增加确认型动作和批量操作协议

## 验收标准

- `新建任务，明天整理数据库` 会真实创建提醒事项
- 模型即使回复“我来帮你处理”，最终气泡也以本地执行结果为准
- 普通闲聊不会落任务
- 远端只返回纯文本时，本地 fallback 仍能兜住明确任务指令
- 执行失败时，聊天里会明确告诉用户失败原因
- 工程编译通过，现有提醒事项读写链路不回退

## 当前阶段定义

这次开发目标不是“一次性删掉所有本地规则”，而是先完成以下切换：

- 主路径：AI 结构化 action
- 备用路径：本地规则 fallback
- 最终回执：本地执行结果生成

做到这一步之后，AIGTD 的行为会从“先口头承诺，再看有没有执行”变成“先识别动作，执行成功后再确认”，这才是更接近真实事务助手的交互方式。
