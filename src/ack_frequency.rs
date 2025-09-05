use crate::connection::path::Path;
use std::cmp;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::ranges::RangeSet;
use crate::{frame::Frame, RecoveryConfig, Result, TransportParams};

/// Parameters from an ACK_FREQUENCY frame, either sent or received.
#[derive(Clone, Debug, PartialEq)]
pub struct AckFrequencyParams {
    pub seq_num: u64,
    pub ack_eliciting_threshold: u64,
    pub req_max_ack_delay: u64, // in microseconds
    pub reordering_threshold: u64,
}

/// An ACK_FREQUENCY frame that has been sent but not yet acknowledged.
#[derive(Clone, Debug)]
pub struct InflightAckFrequencyFrame {
    pub pkt_num: u64,
    pub params: AckFrequencyParams,
}

/// Manages the state of sent ACK_FREQUENCY frames for PTO calculation.
#[derive(Default, Debug)]
pub struct AckFrequencySenderState {
    /// Parameters sent to the peer and acknowledged.
    sent_params: Option<AckFrequencyParams>,

    /// Frames that have been sent but not yet acknowledged.
    inflight_frames: VecDeque<InflightAckFrequencyFrame>,
}

impl AckFrequencySenderState {
    pub fn new() -> Self {
        Default::default()
    }

    pub fn on_ack_frequency_frame_sent(&mut self, pkt_num: u64, frame: &Frame) {
        if let Frame::AckFrequency {
            seq_num,
            ack_eliciting_threshold,
            req_max_ack_delay,
            reordering_threshold,
        } = frame
        {
            let params = AckFrequencyParams {
                seq_num: *seq_num,
                ack_eliciting_threshold: *ack_eliciting_threshold,
                req_max_ack_delay: *req_max_ack_delay,
                reordering_threshold: *reordering_threshold,
            };
            self.inflight_frames
                .push_back(InflightAckFrequencyFrame { pkt_num, params });
        }
    }

    pub fn on_acks_received(&mut self, ack_ranges: &RangeSet) {
        let mut latest_acked_inflight: Option<InflightAckFrequencyFrame> = None;

        self.inflight_frames.retain(|frame| {
            if ack_ranges.contains(frame.pkt_num) {
                if latest_acked_inflight
                    .as_ref()
                    .map_or(true, |latest| frame.pkt_num > latest.pkt_num)
                {
                    latest_acked_inflight = Some(frame.clone());
                }
                false // Remove from inflight_frames
            } else {
                true // Keep in inflight_frames
            }
        });

        if let Some(acked) = latest_acked_inflight {
            self.sent_params = Some(acked.params);
        }
    }

    pub fn get_pto_options(
        &self,
        ack_eliciting_in_flight: u64,
        max_ack_delay: Duration,
    ) -> PtoOptions {
        // 1. Calculate effective_max_ack_delay
        let mut effective_max_ack_delay = max_ack_delay;
        if let Some(sent_params) = &self.sent_params {
            effective_max_ack_delay = Duration::from_micros(sent_params.req_max_ack_delay);
        }
        for frame in &self.inflight_frames {
            effective_max_ack_delay = cmp::max(
                effective_max_ack_delay,
                Duration::from_micros(frame.params.req_max_ack_delay),
            );
        }

        // 2. Calculate exclude_ack_delay
        let mut exclude_ack_delay = false;
        if let Some(params) = &self.sent_params {
            if ack_eliciting_in_flight > params.ack_eliciting_threshold
                && params.reordering_threshold > 0
            {
                exclude_ack_delay = true;
            }
        }

        PtoOptions {
            effective_max_ack_delay,
            exclude_ack_delay,
        }
    }
}

/// Options returned by the manager to guide PTO calculation.
#[derive(Default, Debug)]
pub struct PtoOptions {
    pub effective_max_ack_delay: Duration,
    pub exclude_ack_delay: bool,
}

/// An interface for managing the QUIC ACK Frequency extension.
pub trait AckFrequencyManager: Send + Sync {
    fn on_ack_received(&mut self, stats: &AckFrequencyPathStats) -> Option<Frame>;

    fn on_ack_frequency_frame_received(
        &mut self,
        seq_num: u64,
        ack_eliciting_threshold: u64,
        req_max_ack_delay: u64,
        reordering_threshold: u64,
        local_transport_params: &TransportParams,
    ) -> Result<()>;

    fn get_ack_schedule_params(
        &self,
        recovery_conf: &RecoveryConfig,
        peer_transport_params: &TransportParams,
    ) -> (u64, Duration, u64);

    fn should_send_immediate_ack(&mut self, event: &SendEvent) -> bool;
}

/// The default implementation for the AckFrequencyManager trait.
#[derive(Default)]
pub struct DefaultAckFrequencyManager {
    /// Parameters received from the peer.
    peer_params: Option<AckFrequencyParams>,

    /// The last parameters we sent to the peer.
    last_sent_params: Option<AckFrequencyParams>,

    /// The sequence number for the next ACK_FREQUENCY frame we send.
    next_seq_num: u64,
}

impl DefaultAckFrequencyManager {
    pub fn new() -> Self {
        Default::default()
    }
}

impl AckFrequencyManager for DefaultAckFrequencyManager {
    fn on_ack_received(&mut self, stats: &AckFrequencyPathStats) -> Option<Frame> {
        // Calculate new parameters based on draft recommendations.
        let req_max_ack_delay = (stats.srtt.as_micros() as f64 * 0.075).round() as u64;

        let ack_eliciting_threshold = if stats.max_datagram_size > 0 {
            (((stats.cwnd as f64 * 0.075) / (stats.max_datagram_size as f64)) as u64).max(1)
        } else {
            1
        };

        let new_params = AckFrequencyParams {
            seq_num: self.next_seq_num,
            ack_eliciting_threshold,
            req_max_ack_delay: if stats.min_ack_delay > req_max_ack_delay {
                stats.min_ack_delay
            } else {
                req_max_ack_delay
            },
            reordering_threshold: 3, // Per QUIC-RECOVERY recommendation
        };

        // Only send an update if the parameters have changed.
        if let Some(last_sent) = &self.last_sent_params {
            if (new_params.ack_eliciting_threshold as f64
                - last_sent.ack_eliciting_threshold as f64)
                .abs()
                / (last_sent.ack_eliciting_threshold as f64)
                < 0.1
                && (new_params.req_max_ack_delay as f64 - last_sent.req_max_ack_delay as f64).abs()
                    / (last_sent.req_max_ack_delay as f64)
                    < 0.1
            {
                return None;
            }
        }

        self.last_sent_params = Some(new_params.clone());
        self.next_seq_num += 1;

        Some(Frame::AckFrequency {
            seq_num: new_params.seq_num,
            ack_eliciting_threshold: new_params.ack_eliciting_threshold,
            req_max_ack_delay: new_params.req_max_ack_delay,
            reordering_threshold: new_params.reordering_threshold,
        })
    }

    fn on_ack_frequency_frame_received(
        &mut self,
        seq_num: u64,
        ack_eliciting_threshold: u64,
        req_max_ack_delay: u64,
        reordering_threshold: u64,
        local_transport_params: &TransportParams,
    ) -> Result<()> {
        if let Some(min_ack_delay) = local_transport_params.min_ack_delay {
            if req_max_ack_delay < min_ack_delay {
                return Err(crate::Error::ProtocolViolation);
            }
        }
        if req_max_ack_delay >= (1 << 14) * 1000 {
            return Err(crate::Error::ProtocolViolation);
        }

        if let Some(params) = &self.peer_params {
            if seq_num <= params.seq_num {
                return Ok(());
            }
        }

        self.peer_params = Some(AckFrequencyParams {
            seq_num,
            ack_eliciting_threshold,
            req_max_ack_delay,
            reordering_threshold,
        });

        Ok(())
    }

    fn get_ack_schedule_params(
        &self,
        recovery_conf: &RecoveryConfig,
        peer_transport_params: &TransportParams,
    ) -> (u64, Duration, u64) {
        if let Some(params) = &self.peer_params {
            (
                params.ack_eliciting_threshold+1,
                Duration::from_micros(params.req_max_ack_delay),
                params.reordering_threshold,
            )
        } else {
            (
                recovery_conf.ack_eliciting_threshold,
                Duration::from_millis(peer_transport_params.max_ack_delay),
                1,
            )
        }
    }

    fn should_send_immediate_ack(&mut self, event: &SendEvent) -> bool {
        matches!(event, SendEvent::Pto | SendEvent::Pmtu)
    }
}

/// Statistics about a path, provided to the AckFrequencyManager.
pub struct AckFrequencyPathStats {
    pub min_ack_delay: u64, // in microseconds
    pub srtt: Duration,
    pub min_rtt: Duration,
    pub cwnd: u64,
    pub bytes_in_flight: u64,
    pub max_datagram_size: usize,
}

/// Statistics about the recovery state, provided to the AckFrequencyManager.
#[derive(Default)]
pub struct RecoveryStats {
    pub ack_eliciting_in_flight: u64,
}

/// Events that might trigger sending an IMMEDIATE_ACK frame.
pub enum SendEvent {
    Pto,
    Pmtu,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ranges::RangeSet;
    use std::time::Duration;

    fn initial_stats() -> AckFrequencyPathStats {
        AckFrequencyPathStats {
            min_ack_delay: 1000,
            srtt: Duration::from_millis(100),
            min_rtt: Duration::from_millis(100),
            cwnd: 12000,
            bytes_in_flight: 0,
            max_datagram_size: 1200,
        }
    }

    #[test]
    fn test_initial_ack_frequency_frame() {
        let mut manager = DefaultAckFrequencyManager::new();
        let stats = initial_stats();

        let frame = manager.on_ack_received(&stats);
        assert!(frame.is_some());

        if let Some(Frame::AckFrequency { seq_num, .. }) = frame {
            assert_eq!(seq_num, 0);
        } else {
            panic!("Expected AckFrequency frame");
        }
    }

    #[test]
    fn test_no_change_no_frame() {
        let mut manager = DefaultAckFrequencyManager::new();
        let stats = initial_stats();

        // First call, should send a frame
        let frame1 = manager.on_ack_received(&stats);
        assert!(frame1.is_some());
        assert_eq!(manager.next_seq_num, 1);

        // Second call with identical stats, should not send a frame
        let frame2 = manager.on_ack_received(&stats);
        assert!(frame2.is_none());
    }

    #[test]
    fn test_threshold_change_sends_frame() {
        let mut manager = DefaultAckFrequencyManager::new();
        let mut stats = initial_stats();

        // First call
        let _ = manager.on_ack_received(&stats);
        assert_eq!(manager.next_seq_num, 1);

        // Change cwnd to alter the threshold
        stats.cwnd = 24000; // threshold should become 20
        let frame = manager.on_ack_received(&stats);
        assert!(frame.is_some());

        if let Some(Frame::AckFrequency {
            seq_num,
            ack_eliciting_threshold,
            ..
        }) = frame
        {
            assert_eq!(seq_num, 1);
            assert_eq!(ack_eliciting_threshold, 20);
        } else {
            panic!("Expected AckFrequency frame");
        }
    }

    #[test]
    fn test_significant_delay_change_sends_frame() {
        let mut manager = DefaultAckFrequencyManager::new();
        let mut stats = initial_stats();

        // First call
        let _ = manager.on_ack_received(&stats);
        assert_eq!(manager.next_seq_num, 1);

        // Change srtt by more than 10%
        stats.srtt = Duration::from_millis(120); // 20% increase
        let frame = manager.on_ack_received(&stats);
        assert!(frame.is_some());

        if let Some(Frame::AckFrequency {
            seq_num,
            req_max_ack_delay,
            ..
        }) = frame
        {
            assert_eq!(seq_num, 1);
            assert_eq!(req_max_ack_delay, 120_000);
        } else {
            panic!("Expected AckFrequency frame");
        }
    }

    #[test]
    fn test_minor_delay_change_no_frame() {
        let mut manager = DefaultAckFrequencyManager::new();
        let mut stats = initial_stats();

        // First call
        let _ = manager.on_ack_received(&stats);
        assert_eq!(manager.next_seq_num, 1);

        // Change srtt by less than 10%
        stats.srtt = Duration::from_millis(105); // 5% increase
        let frame = manager.on_ack_received(&stats);
        assert!(frame.is_none());
    }

    #[test]
    fn test_sequence_number_increases() {
        let mut manager = DefaultAckFrequencyManager::new();
        let mut stats = initial_stats();

        // First frame
        let frame1 = manager.on_ack_received(&stats);
        if let Some(Frame::AckFrequency { seq_num, .. }) = frame1 {
            assert_eq!(seq_num, 0);
        } else {
            panic!("Expected AckFrequency frame");
        }

        // Change stats to trigger another frame
        stats.cwnd = 36000;
        let frame2 = manager.on_ack_received(&stats);
        if let Some(Frame::AckFrequency { seq_num, .. }) = frame2 {
            assert_eq!(seq_num, 1);
        } else {
            panic!("Expected AckFrequency frame");
        }

        // Another change
        stats.srtt = Duration::from_millis(200);
        let frame3 = manager.on_ack_received(&stats);
        if let Some(Frame::AckFrequency { seq_num, .. }) = frame3 {
            assert_eq!(seq_num, 2);
        } else {
            panic!("Expected AckFrequency frame");
        }
    }

    #[test]
    fn test_ack_sender_state_tracking() {
        let mut state = AckFrequencySenderState::new();
        let frame = Frame::AckFrequency {
            seq_num: 0,
            ack_eliciting_threshold: 2,
            req_max_ack_delay: 25000,
            reordering_threshold: 3,
        };

        state.on_ack_frequency_frame_sent(10, &frame);
        assert_eq!(state.inflight_frames.len(), 1);

        let mut acks = RangeSet::new(16);
        acks.insert(10..11);
        state.on_acks_received(&acks);

        assert_eq!(state.inflight_frames.len(), 0);
        assert!(state.sent_params.is_some());
        let params = state.sent_params.as_ref().unwrap();
        assert_eq!(params.seq_num, 0);
    }

    #[test]
    fn test_pto_options_calculation() {
        let mut state = AckFrequencySenderState::new();
        let default_max_ack_delay = Duration::from_millis(25);

        // Scenario 1: No frames sent
        let options = state.get_pto_options(0, default_max_ack_delay);
        assert_eq!(options.effective_max_ack_delay, default_max_ack_delay);
        assert!(!options.exclude_ack_delay);

        // Scenario 2: Frame in-flight
        let frame = Frame::AckFrequency {
            seq_num: 0,
            ack_eliciting_threshold: 5,
            req_max_ack_delay: 50000, // 50ms
            reordering_threshold: 3,
        };
        state.on_ack_frequency_frame_sent(20, &frame);
        let options = state.get_pto_options(0, default_max_ack_delay);
        assert_eq!(
            options.effective_max_ack_delay,
            Duration::from_micros(50000)
        );

        // Scenario 3: Frame acked, test exclude_ack_delay
        let mut acks = RangeSet::new(16);
        acks.insert(20..21);
        state.on_acks_received(&acks);

        // ack_eliciting_in_flight <= threshold
        let options = state.get_pto_options(5, default_max_ack_delay);
        assert!(!options.exclude_ack_delay);

        // ack_eliciting_in_flight > threshold
        let options = state.get_pto_options(6, default_max_ack_delay);
        assert!(options.exclude_ack_delay);

        // reordering_threshold = 0
        state.sent_params.as_mut().unwrap().reordering_threshold = 0;
        let options = state.get_pto_options(6, default_max_ack_delay);
        assert!(!options.exclude_ack_delay);
    }
}
