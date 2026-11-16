import { spawn } from "node:child_process"

export default {
  id: "notification",
  async setup(ctx) {
    const controller = new AbortController()

    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (event.type === "permission.asked") {
          spawn("notify-send", ["OpenCode", "Approval needed"], { stdio: "ignore" })
        }
      }
    })()

    return () => controller.abort()
  },
}
