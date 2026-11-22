/** Cheap composer tests use the real microphone graph with a fake stream and model worker. */
export function mockDictation({ text, needsDownload = false }) {
  const RealWorker = window.Worker;
  window.dictationFixture = { needsDownload, failure: null, hold: false, inferences: 0 };
  window.Worker = class {
    constructor(url, options) {
      if (!String(url).includes("parakeet.worker")) return new RealWorker(url, options);
    }
    postMessage(message) {
      const fixture = window.dictationFixture;
      const report = data => queueMicrotask(() => this.onmessage?.({ data }));
      if (message.kind === "prepare") {
        if (fixture.needsDownload && !message.download) return report({ kind: "needsDownload" });
        fixture.needsDownload = false;
        return report({ kind: "ready" });
      }
      fixture.inferences++;
      if (fixture.hold) return;
      if (fixture.failure) return report({ kind: "failed", message: fixture.failure });
      report({ kind: "transcript", text });
    }
    terminate() {}
  };
  navigator.mediaDevices.getUserMedia = async () => {
    const context = new AudioContext();
    const destination = context.createMediaStreamDestination();
    const [track] = destination.stream.getAudioTracks();
    const stop = track.stop.bind(track);
    track.stop = () => { stop(); void context.close(); };
    return destination.stream;
  };
}
