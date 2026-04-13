# 语音识别流式协议说明

## 结论

豆包语音识别这条链，最终要支持两种返回方式：

- `partial`：实时识别中的中间结果
- `final`：识别完成后的最终结果

当前协议层已经改成支持流式回调，但 Chat UI 还没有接入这套回调展示。

## 协议调整

原先的协议只有单次完成式接口：

- `transcribe(_ request:) async throws -> VoiceTranscriptionResult`

现在增加了带更新回调的版本：

- `transcribe(_ request:onUpdate:) async throws -> VoiceTranscriptionResult`

其中 `onUpdate` 接收：

- `partial(String)`
- `finalTranscript(String)`

## 为什么要这样改

当前豆包流式语音识别接口的体验目标是：

- 边说边出字
- 结束后再做最终修正

如果只保留一次性返回，就会退化成“录完再整段显示”，无法满足飞书 IM / 豆包式的输入体验。

## 当前实现状态

- `VoiceTranscriptionService` 已支持带回调协议
- `DoubaoASRService` 已在 WebSocket 流上发出 `partial / final` 回调
- `VoiceRecorderService` 暂未改动，仍负责录音文件采集
- Chat UI 暂未接入这套回调

## 后续接入建议

后续把 UI 接上时，建议按这个顺序：

1. 语音按钮进入录音态
2. `partial` 直接回填输入框
3. `final` 覆盖输入框内容
4. 如果启用自动发送，再在 `final` 后自动发送

## 风险

- 现阶段仅协议层具备流式能力，UI 还没有验证 partial 回填效果
- `final` 和 `partial` 的回调触发时机，需要后续在真机上再确认一次
- 当前录音文件仍是本地临时 wav，后续若要更稳的流式体验，可能还要进一步优化音频分片和取消策略

