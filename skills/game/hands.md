# hands —— 手：三个工具

只有三个，够用就不加。

## `game_shot` —— 看一眼

```
game_shot({ region?: {x,y,w,h}, scale?: 0.2~1 })
```

- `region` 是**客户区相对坐标**（窗口内），不是屏幕坐标。
- 默认 `scale 0.5`；**读小字**用 `0.8~1`，**看大局**用 `0.4`。
- 回一张 PNG + 一行尺寸说明。

## `game_do` —— 做一段 + 顺便看

```
game_do({ steps: [...], every?: ms, maxFrames?: 1~12, scale?, region? })
```

一个 step 的五种形态：

| 形态 | 例子 | 说明 |
| --- | --- | --- |
| 按键 | `{"t":"key","k":"w","a":"tap","ms":120}` | `a` = `tap`/`down`/`up`；`repeat` 连按，`gap` 间隔 |
| 鼠标 | `{"t":"mouse","a":"click","btn":"left"}` | `a` = `click`/`down`/`up`/`rel`(dx,dy)/`abs`(x,y)/`wheel`(dy) |
| 等待 | `{"t":"wait","ms":800}` | 演出、加载的留白，别用连点糊过去 |
| 拍摄 | `{"t":"look"}` | 在动作中间插一帧（"按下前/按下后"对比） |
| **等信号** | `{"t":"waitfor","probe":"qte","timeoutMs":1200,"then":{"t":"mouse","a":"click","btn":"left"}}` | **反射**：手在本地每 ~40ms 轮询一次，命中就立刻执行 `then`，超时就静默跳过 |

### waitfor —— 唯一需要"毫秒级"的动作

我一次思考要几秒，QTE 窗口只有约 1.2 秒，**这类判断绝不能交给我**。

```json
{"t":"waitfor","probe":"qte","timeoutMs":1200,
 "then":{"t":"mouse","a":"click","btn":"left","repeat":1}}
```

- `probe`：`"qte"` / `"qte_right"`，或内联对象
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
