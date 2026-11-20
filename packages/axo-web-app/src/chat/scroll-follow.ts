/** Browser geometry for one scroll event, which may arrive after content grows. */
export interface ScrollObservation {
  wasFollowing: boolean;
  previousTop: number;
  top: number;
  fromEnd: number;
}

const FOLLOW_SLACK_PX = 80;

export function followsAfterScroll({ wasFollowing, previousTop, top, fromEnd }: ScrollObservation): boolean {
  const goingUp = top < previousTop - 0.5;
  // A queued programmatic scroll can be delivered after a row grew. Distance
  // alone is not evidence the reader left; actual upward movement is.
  return fromEnd < 1 || (!goingUp && (wasFollowing || fromEnd < FOLLOW_SLACK_PX));
}
