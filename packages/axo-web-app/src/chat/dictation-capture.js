// This only captures PCM; the audio graph outputs silence, never microphone monitoring.
class DictationCapture extends AudioWorkletProcessor {
  batch = new Float32Array(2048);
  length = 0;
  stopped = false;

  constructor() {
    super();
    this.port.onmessage = () => {
      this.stopped = true;
      this.flush();
      this.port.postMessage(null);
    };
  }

  flush() {
    if (!this.length) return;
    const samples = this.length === this.batch.length ? this.batch : this.batch.slice(0, this.length);
    this.port.postMessage(samples, [samples.buffer]);
    this.batch = new Float32Array(2048);
    this.length = 0;
  }

  process(inputs) {
    if (this.stopped) return false;
    const samples = inputs[0]?.[0];
    if (samples) {
      for (const sample of samples) {
        this.batch[this.length++] = sample;
        if (this.length === this.batch.length) this.flush();
      }
    }
    return true;
  }
}

registerProcessor("dictation-capture", DictationCapture);
