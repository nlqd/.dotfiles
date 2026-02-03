export const NotificationPlugin = async ({ $ }) => {
  return {
    event: async ({ event }) => {
      if (event.type === "permission.asked") {
        await $`notify-netcat "OpenCode" "Approval needed"`
      }
    }
  }
}
