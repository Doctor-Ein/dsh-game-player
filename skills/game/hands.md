# hands —— 手：四个操作工具

连接后使用 game_shot / game_find / game_do / game_stop；定位用物理像素，QTE 仍走本地反射。

完整参数、返回格式、错误恢复及兼容性变化见 [DSH 接口交接](../../docs/interfaces-v2.md)。

传 region 时必须完整给出整数 x/y/w/h，不能只传宽高；不裁剪时整个省略。game_find 的 matches 在返回 text 的 JSON 内，不是顶层字段。

## `game_shot` —— 看一眼

```
game_shot({ region?: {x,y,w,h}, scale?: 0.2~1, overlay?: true })
```

- `region` 是**客户区相对坐标**（窗口内），不是屏幕坐标。
- 默认 `scale 0.5`；**读小字**用 `0.8~1`，**看大局**用 `0.4`。
- 返回 PNG、shotId、未缩放原图尺寸、屏幕原点和实际 X/Y 缩放；overlay 网格标注屏幕物理坐标。
- region 使用客户区物理像素；鼠标 x/y 使用屏幕物理像素，允许负数，不能拿宫格像素直接点击。

## `game_find` —— 工具给出坐标

先 `game_shot({overlay:true})`，再从它的原图录制：

```js
game_find({template:"enter-v1",record:{shotId:"返回的值",region:{x:100,y:100,w:120,h:60}}})
game_find({template:"enter-v1",threshold:0.9,region:{x:0,y:0,w:800,h:600}})
```

region 是客户区物理像素；数值只是格式示例。检查录制返回的裁片，再查找。matches 中 center 是屏幕物理坐标，直接填 game_do 的 click x/y。工具不自动点击。无匹配返回 []，不要猜坐标补偿。

模板每边 3–512px，必须有纹理、与当前 UI 尺寸/状态一致。阈值为 RGB 像素相似度，不是概率；默认 .9。限定 region 提速。命名模板存 TEMP，重开手后还在；shotId 仅对当前手最近 16 次截图有效。

## `game_do` —— 做一段 + 顺便看

```
game_do({ steps: [...], every?: ms, maxFrames?: 1~12, scale?, region? })
```

一个 step 的五种形态：

| 形态 | 例子 | 说明 |
| --- | --- | --- |
| 按键 | `{"t":"key","k":"w","a":"tap","ms":120}` | `a` = `tap`/`down`/`up`；`repeat` 连按，`gap` 间隔 |
| 鼠标 | `{"t":"mouse","a":"click","btn":"left"}` | `a` = `click`/`down`/`up`/`rel`(dx,dy)/`abs`(屏幕物理 x,y)/`wheel`(dy)；click 也可带 x/y 先移动再点击 |
| 等待 | `{"t":"wait","ms":800}` | 演出、加载的留白，别用连点糊过去 |
| 拍摄 | `{"t":"look"}` | 在动作中间插一帧（"按下前/按下后"对比） |
| **等信号** | `{"t":"waitfor","probe":"qte","timeoutMs":1200,"then":{"t":"mouse","a":"click","btn":"left"}}` | **反射**：手在本地每 ~40ms 轮询一次，命中就立刻执行 `then`，超时就静默跳过 |

### waitfor —— 唯一需要"毫秒级"的动作

我一次思考要几秒，QTE 窗口只有约 1.2 秒，**这类判断绝不能交给我**。

```json
{"t":"waitfor","probe":"qte","timeoutMs":1200,
 "then":{"t":"mouse","a":"click","btn":"left","repeat":1}}
```

- `probe`：绝区零使用 `"qte_counterattack"`（反击，右键）和 `"qte_flag"`（主动，左键）；保留 `"qte"` / `"qte_right"` 等通用探针，也可用内联对象
  `{"region":{"x":0.55,"y":0.02,"w":0.32,"h":0.30},"color":"cyan","minPixels":120,"stride":5}`
  （`region` 用**客户区比例**，换分辨率不用改）
- `then`：单个 step 或数组；支持 key / mouse（带 `repeat` 连点）/ wait / look
- 超时**不算错误**，trace 里会写 `hit:false`，你看一眼就知道它有没有接住
- 一次块里可以放多个 waitfor，但别把整块都堆成反射——先按技能，再等

- 回一张**编号宫格**，每格左上角是序号 + 相对时间（`1 0.1s`）。
- 一次块建议 3–8 步、2–5 秒游戏时间。
- 块内的 `every` 默认 1000ms、最多 12 帧；**帧多了图会变小，认不出细节**。

## `game_stop` —— 松手

```
game_stop({})
```

松开所有键/鼠标、结束本次绑定。关卡结束、出意外、要交还控制权时都要调。

## 常见错误

| 现象 | 原因 |
| --- | --- |
| `bound window is not foreground` | 游戏被切到后台了，先把窗口放回前台 |
| 截出来全黑 | 独占全屏。让游戏改成无边框窗口 |
| **所有键都没反应** | **手没有管理员权限**（UIPI 静默丢弃，不报错）。看到 `NOT elevated` 就重开，启动器会弹 UAC |
| 按键没反应（已提权） | 游戏用原始输入，把 `ms` 放长到 100~150；或先点一下游戏拿焦点 |
| 帧里没变化 | `every` 太密（帧挨太近）或这一块本来就没动 |
| 抓到的画面是别的窗口 | 截图只抓屏幕像素，没抢到前台的窗口会被拍进去 |
