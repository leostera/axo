import type { RemoteMethod } from "@axo/protocol";

export type Route = {
  connection_id: string;
  machine_id: string;
  generation: string | null;
  lease_until: number;
  ready: number;
};
export type Group = {
  group_id: string;
  connection_id: string;
  batch: number;
  remaining: number;
  replies: string;
};
export type Pending = {
  hop_id: string;
  group_id: string;
  original_id: string;
  connection_id: string;
  method: RemoteMethod;
  generation: string;
  deadline: number;
};
