//! Bounded presentation delivery. PTY read fragmentation is not frame pressure.
use crate::terminal::{BACKLOG_BYTES, Frame, OUTPUT_CHUNK};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicU8, AtomicUsize, Ordering},
        mpsc::{RecvError, RecvTimeoutError, TryRecvError},
    },
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum DeliveryLoss {
    QueueCapacity = 1,
    InvalidFrame = 2,
    OutputFailed = 3,
    ReceiverReleased = 4,
}

struct State {
    frames: VecDeque<Frame>,
    closed: bool,
}
struct Shared {
    state: Mutex<State>,
    ready: Condvar,
    capacity: usize,
    senders: AtomicUsize,
    loss: AtomicU8,
}
impl Shared {
    fn record_loss(&self, reason: DeliveryLoss) {
        // Preserve the first loss; teardown must not rewrite overload or I/O evidence.
        let _ = self
            .loss
            .compare_exchange(0, reason as u8, Ordering::SeqCst, Ordering::SeqCst);
    }
    fn loss(&self) -> Option<DeliveryLoss> {
        match self.loss.load(Ordering::SeqCst) {
            0 => None,
            1 => Some(DeliveryLoss::QueueCapacity),
            2 => Some(DeliveryLoss::InvalidFrame),
            3 => Some(DeliveryLoss::OutputFailed),
            4 => Some(DeliveryLoss::ReceiverReleased),
            _ => unreachable!("Only closed delivery loss variants are stored"),
        }
    }
}
pub struct Sink {
    shared: Arc<Shared>,
}
pub struct OutputReceiver {
    shared: Arc<Shared>,
}

impl Sink {
    pub fn bounded(capacity: usize) -> (Self, OutputReceiver) {
        assert!((1..=32).contains(&capacity));
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                frames: VecDeque::new(),
                closed: false,
            }),
            ready: Condvar::new(),
            capacity,
            senders: AtomicUsize::new(1),
            loss: AtomicU8::new(0),
        });
        (
            Self {
                shared: shared.clone(),
            },
            OutputReceiver { shared },
        )
    }
    pub fn is_disconnected(&self) -> bool {
        self.shared.loss.load(Ordering::SeqCst) != 0
    }
    pub fn disconnect(&self, reason: DeliveryLoss) {
        self.shared.record_loss(reason);
        self.shared.state.lock().unwrap().closed = true;
        self.shared.ready.notify_all();
    }
    pub fn send(&self, frame: Frame) -> bool {
        let mut state = self.shared.state.lock().unwrap();
        if state.closed || self.shared.loss.load(Ordering::SeqCst) != 0 {
            return false;
        }
        // A single queued output frame is always <= OUTPUT_CHUNK; initial replay
        // remains <= BACKLOG_BYTES. Never merge across identity, offset or control.
        let valid = match &frame {
            Frame::Output { offset, data, .. } => {
                !data.is_empty()
                    && data.len() <= OUTPUT_CHUNK
                    && offset.checked_add(data.len() as u64).is_some()
            }
            Frame::Attached { backlog, .. } => backlog.data.len() <= BACKLOG_BYTES,
            Frame::Exited { .. } => true,
        };
        if valid && append(&mut state.frames, frame, self.shared.capacity) {
            self.shared.ready.notify_one();
            return true;
        }
        self.shared.record_loss(if valid {
            DeliveryLoss::QueueCapacity
        } else {
            DeliveryLoss::InvalidFrame
        });
        state.closed = true;
        self.shared.ready.notify_all();
        false
    }
}
impl Clone for Sink {
    fn clone(&self) -> Self {
        self.shared.senders.fetch_add(1, Ordering::SeqCst);
        Self {
            shared: self.shared.clone(),
        }
    }
}
impl Drop for Sink {
    fn drop(&mut self) {
        if self.shared.senders.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.shared.state.lock().unwrap().closed = true;
            self.shared.ready.notify_all();
        }
    }
}

/// Coalescing is all-or-nothing: a failed insertion never mutates a queued prefix.
fn append(frames: &mut VecDeque<Frame>, frame: Frame, capacity: usize) -> bool {
    if let Frame::Output {
        attachment,
        offset,
        data,
    } = &frame
        && let Some(Frame::Output {
            attachment: previous,
            offset: start,
            data: queued,
        }) = frames.back_mut()
        && previous == attachment
        && start.checked_add(queued.len() as u64) == Some(*offset)
    {
        let room = OUTPUT_CHUNK - queued.len();
        if data.len() <= room {
            queued.extend_from_slice(data);
            return true;
        }
        if frames.len() == capacity {
            return false;
        }
        // Reborrow after checking capacity to keep the mutation atomic.
        let Some(Frame::Output { data: queued, .. }) = frames.back_mut() else {
            unreachable!()
        };
        queued.extend_from_slice(&data[..room]);
        frames.push_back(Frame::Output {
            attachment: *attachment,
            offset: offset + room as u64,
            data: data[room..].to_vec(),
        });
        return true;
    }
    if frames.len() == capacity {
        return false;
    }
    frames.push_back(frame);
    true
}

impl OutputReceiver {
    pub fn loss(&self) -> Option<DeliveryLoss> {
        self.shared.loss()
    }
    pub fn is_disconnected(&self) -> bool {
        self.shared.loss.load(Ordering::SeqCst) != 0
    }
    pub fn try_recv(&self) -> Result<Frame, TryRecvError> {
        let mut state = self.shared.state.lock().unwrap();
        if let Some(frame) = state.frames.pop_front() {
            return Ok(frame);
        }
        Err(if state.closed {
            TryRecvError::Disconnected
        } else {
            TryRecvError::Empty
        })
    }
    pub fn recv(&self) -> Result<Frame, RecvError> {
        let mut state = self.shared.state.lock().unwrap();
        loop {
            if let Some(frame) = state.frames.pop_front() {
                return Ok(frame);
            }
            if state.closed {
                return Err(RecvError);
            }
            state = self.shared.ready.wait(state).unwrap();
        }
    }
    pub fn recv_timeout(&self, timeout: Duration) -> Result<Frame, RecvTimeoutError> {
        let deadline = Instant::now() + timeout;
        let mut state = self.shared.state.lock().unwrap();
        loop {
            if let Some(frame) = state.frames.pop_front() {
                return Ok(frame);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or(RecvTimeoutError::Timeout)?;
            state = self.shared.ready.wait_timeout(state, remaining).unwrap().0;
        }
    }
}
impl Drop for OutputReceiver {
    fn drop(&mut self) {
        self.shared.record_loss(DeliveryLoss::ReceiverReleased);
        self.shared.state.lock().unwrap().closed = true;
        self.shared.ready.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::*;

    fn attachment() -> AttachmentRef {
        AttachmentRef {
            runtime: RuntimeRef {
                host_generation: HostGeneration::new(),
                target: TerminalTarget {
                    session_id: SessionId::new(),
                    pane_id: PaneId::new(),
                },
                runtime_generation: RuntimeGeneration::new(),
            },
            attachment_id: AttachmentId::new(),
        }
    }
    fn output(attachment: AttachmentRef, offset: u64, data: Vec<u8>) -> Frame {
        Frame::Output {
            attachment,
            offset,
            data,
        }
    }
    #[test]
    fn one_byte_reads_do_not_exhaust_frame_capacity_and_bytes_stay_exact() {
        let (sink, receiver) = Sink::bounded(2);
        let identity = attachment();
        let bytes: Vec<_> = (0..1500).map(|index| (index % 251) as u8).collect();
        for (offset, byte) in bytes.iter().enumerate() {
            assert!(sink.send(output(identity, offset as u64, vec![*byte])));
        }
        assert!(!receiver.is_disconnected());
        let mut delivered = Vec::new();
        let mut frames = 0;
        while let Ok(frame) = receiver.try_recv() {
            let Frame::Output {
                attachment,
                offset,
                data,
            } = frame
            else {
                panic!("Output expected")
            };
            assert_eq!(attachment, identity);
            assert_eq!(offset, delivered.len() as u64);
            assert!(data.len() <= OUTPUT_CHUNK);
            delivered.extend_from_slice(&data);
            frames += 1;
        }
        assert_eq!(frames, 2);
        assert_eq!(delivered, bytes);
    }
    #[test]
    fn full_queue_rejects_without_mutating_an_unaccepted_prefix() {
        let (sink, receiver) = Sink::bounded(1);
        let identity = attachment();
        assert!(sink.send(output(identity, 0, vec![1; OUTPUT_CHUNK - 1])));
        assert!(!sink.send(output(identity, (OUTPUT_CHUNK - 1) as u64, vec![2; 2])));
        assert!(receiver.is_disconnected());
        assert_eq!(receiver.loss(), Some(DeliveryLoss::QueueCapacity));
        sink.disconnect(DeliveryLoss::OutputFailed);
        assert_eq!(receiver.loss(), Some(DeliveryLoss::QueueCapacity));
        let Frame::Output { data, .. } = receiver.recv().unwrap() else {
            panic!("Output expected")
        };
        assert_eq!(data, vec![1; OUTPUT_CHUNK - 1]);
        assert!(matches!(
            receiver.try_recv(),
            Err(TryRecvError::Disconnected)
        ));
        assert!(!sink.send(output(identity, OUTPUT_CHUNK as u64, vec![3])));
    }
    #[test]
    fn identity_gaps_and_control_frames_never_coalesce() {
        let (sink, receiver) = Sink::bounded(8);
        let first = attachment();
        let second = attachment();
        assert!(sink.send(output(first, 0, vec![1])));
        assert!(sink.send(output(first, 3, vec![2])));
        assert!(sink.send(output(second, 4, vec![3])));
        assert!(sink.send(Frame::Exited {
            attachment: second,
            wait_status: 0
        }));
        assert!(sink.send(output(second, 5, vec![4])));
        let mut count = 0;
        while receiver.try_recv().is_ok() {
            count += 1;
        }
        assert_eq!(count, 5);
    }
    #[test]
    fn last_sender_and_receiver_loss_wake_and_close_without_work_authority() {
        let (sink, receiver) = Sink::bounded(1);
        let copy = sink.clone();
        drop(sink);
        assert!(matches!(
            receiver.recv_timeout(Duration::ZERO),
            Err(RecvTimeoutError::Timeout)
        ));
        drop(copy);
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(1)),
            Err(RecvTimeoutError::Disconnected)
        ));
        let (sink, receiver) = Sink::bounded(1);
        drop(receiver);
        assert!(sink.is_disconnected());
        assert!(!sink.send(output(attachment(), 0, vec![1])));
        assert_eq!(sink.shared.loss(), Some(DeliveryLoss::ReceiverReleased));
        let (sink, receiver) = Sink::bounded(1);
        sink.disconnect(DeliveryLoss::OutputFailed);
        assert_eq!(receiver.loss(), Some(DeliveryLoss::OutputFailed));
    }
    #[test]
    fn oversize_or_overflow_output_fails_closed() {
        for (offset, bytes) in [(0, OUTPUT_CHUNK + 1), (u64::MAX, 1)] {
            let (sink, receiver) = Sink::bounded(1);
            assert!(!sink.send(output(attachment(), offset, vec![0; bytes])));
            assert!(receiver.is_disconnected());
            assert_eq!(receiver.loss(), Some(DeliveryLoss::InvalidFrame));
            assert!(matches!(
                receiver.try_recv(),
                Err(TryRecvError::Disconnected)
            ));
        }
    }
}
