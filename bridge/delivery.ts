export function promptDelivery(isIdle: boolean): { deliverAs: "steer" } | undefined {
  return isIdle ? undefined : { deliverAs: "steer" };
}
