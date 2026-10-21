# GPS_ProcessData architecture and existing behavior

This document describes the supplied implementation. This revision changes comments and documentation without modifying HDL behavior, clocks, IP settings, or interfaces.

## Data flow and clocks

```text
GPS TX -> GPS_rx -> uart_paritycheck_gps -> byte history -> UART_FIFO
                     UART_Clk             UART_Clk       write: UART_Clk
                                             |           read:  clk_dsp
                                             +-> GPS_TIME       |
                                             +-> RMC event      +-> GPS_buf_data
                                                    |
                                                    +-> FDCE chain -> GPS_frame_tick_O

GPS_PPS_1s -> Debounce_v2 [ADC_SamplingClk] -> GPS_PPS_1s_Debunced_Elint
           -> Debounce_v2 [clk_dsp]         -> GPS_PPS_1s_Debunced_Comint
```

`reset` is active high. RX, byte history, and time extraction operate in `UART_Clk`. The FIFO has independent write and read clocks. `GPS_TIME` belongs to `UART_Clk`; the top level provides no separate register transfer or handshake for moving it into `clk_dsp`.

## UART reception and byte acceptance

The UART uses integer dividers to generate baud and oversampling enables. The RX state machine qualifies a low start interval and then samples data, optional parity, and the stop bit. Integer division of the clock-to-baud and oversampling ratios affects the achieved rates.

At receive completion, `rx_data` and `rx_error` update together and `rx_ena` goes high. That enable stays high until the next oversampling-enabled idle update, so it is not necessarily one `UART_Clk` cycle wide. In the top level, `GPS_rx_full` is connected to `rx_ena`. Its rising edge produces internal request `GPS_rd` only when `GPS_rx_error` is low.

`GPS_rx_error` combines start, optional parity, and stop errors. It does not check an NMEA sentence checksum. UART bytes reported as erroneous are excluded from the history. The top level disables the reusable transmitter with `tx_ena = '0'` and leaves its outputs unconnected.

## Byte history and time extraction

`GPS_Reg_data` contains 21 bytes indexed 0 through 20. When `GPS_rd = '1'`, the received byte loads index 0 and older bytes shift toward higher indices. VHDL signal assignments cause processes on the same edge to read previous signal values, introducing register delays between reception, shifting, and recognition.

Recognition conditions are evaluated on every `UART_Clk` cycle, including cycles without a new byte. A match can therefore remain high between byte arrivals.

| Index | Meaning at a match |
| --- | --- |
| 17 | `$`, value `0x24` |
| 16 | `G`, value `0x47` |
| 15 | Must be `N` for `GPS_frame_PPS`; unchecked for `GPS_frame_tick` |
| 14, 13, 12 | `R`, `M`, `C` |
| 11 | Comma, value `0x2C` |
| 10 through 5 | Six selected time bytes |
| 4 through 0 | Bytes after the six time characters; not checked by the active conditions |
| 18 | Older byte connected to the FIFO data input |

Two independent conditions are used:

- `GPS_frame_PPS` matches only `$GNRMC,` and triggers the frame notification circuit.
- `GPS_frame_tick` matches `$G?RMC,`; index 15 is omitted from the active expression. This condition updates the time output and participates in capture arming. For example, `$GPRMC,` can satisfy this condition without satisfying the first one.

The time output is mapped as follows:

| Output bits | Source register | Expected character |
| --- | --- | --- |
| `47:40` | `GPS_Reg_data(10)` | Hour tens, ASCII |
| `39:32` | `GPS_Reg_data(9)` | Hour units, ASCII |
| `31:24` | `GPS_Reg_data(8)` | Minute tens, ASCII |
| `23:16` | `GPS_Reg_data(7)` | Minute units, ASCII |
| `15:8` | `GPS_Reg_data(6)` | Second tens, ASCII |
| `7:0` | `GPS_Reg_data(5)` | Second units, ASCII |

The logic does not validate digits, time-field length, fractional seconds, `A/V` status, date, or checksum. `GPS_TIME` resets to zero and holds its previous value without another match. Here, `GPS_frame_PPS` names a text-derived match signal; it is not derived from physical input `GPS_PPS_1s`.

## FIFO capture and reading

The supplied IP is configured as `Independent_Clocks_Block_RAM`, with 8-bit input/output, 512 entries, `Standard_FIFO` mode, and asynchronous reset. These values come from the supplied IP configuration.

1. When `GPS_frame_tick = '1'` and `GPS_buf_empty = '1'`, `GPS_buf_WRen` is set.
2. Otherwise, a full FIFO clears `GPS_buf_WRen`. Priority follows the existing `if/elsif` order.
3. While capture is armed, `uld_rx_data` registers `GPS_rd`; otherwise it registers zero.
4. FIFO `wr_en` is connected to `uld_rx_data`, and `din` is connected to `GPS_Reg_data(18)`. These registers produce a delayed byte capture path.
5. `GPS_buf_rd_en` requests reads in `clk_dsp`; FIFO `dout` directly drives `GPS_buf_data`.

Capture does not stop at the end of RMC or at CR/LF, so the buffer does not necessarily contain one complete NMEA sentence. Concurrent reading can affect whether and when the FIFO becomes full. `Standard_FIFO` uses the IP's requested-read and output-latency contract; it is not configured for first-word fall-through (FWFT).

`GPS_buf_full_O` exposes full from the write domain. Empty is used internally but is not exported. Count and reset-busy ports appear in the component declaration but are omitted from the existing port map. The interface also has no data-valid output; the consumer integration must define read timing and the number of reads.

## FDCE frame notification circuit

- `FDCE_inst` is clocked by a rising edge of `GPS_frame_PPS` and latches one into `GPS_frame_tick_int1`.
- `FDCE_inst2` samples that value in `clk_dsp`; its output drives `GPS_frame_tick_O`.
- `FDCE_inst3` samples the second stage into `GPS_frame_tick_Rst` in `clk_dsp`.
- `Clear = reset or GPS_frame_tick_Rst` asynchronously clears the first two stages. The third stage is cleared by `reset` itself.

This circuit transfers an RMC text notification. It does not validate alignment with the external PPS edge or the validity of the received GPS time. Actual notification width depends on the clock/clear circuit and has not been measured by simulation or timing analysis in this documentation change.

## PPS filtering

Two independent `Debounce_v2` instances filter the shared `GPS_PPS_1s` input in separate clock domains. Both use `WaitCnt = x"0A"`. An input change clears the counter; an unchanged sampled level allows it to count to the threshold before updating the output. Both transitions are filtered, and the output is a level rather than a one-cycle pulse.

Because the threshold comparison precedes incrementing, after a detected transition clears the counter, a threshold of 10 updates the output on the eleventh unchanged comparison. The delay is measured in local clock cycles; initial detection also depends on input phase relative to the clock. `DinD1` is the previous sample for change detection, not a separate two-stage synchronizer. The historical implementation at the end of the file is entirely commented out and inactive.

## Existing integration considerations

- RX samples `GPS_rx` directly; the UART file contains no separate input synchronizer chain.
- The FIFO read-domain `GPS_buf_empty` signal is used by `UART_Clk` logic without a separate synchronizer in this top-level HDL.
- Multibit `GPS_TIME` and `GPS_buf_full_O` are exported directly. Consumption in another clock domain needs a transfer contract in the integrating system.
- Some pipeline signals, including `GPS_rx_full_d1` and `uld_rx_data`, have no assignments in the main process's reset branch. Their existing behavior is preserved.
- Recognition uses fixed byte positions rather than a complete NMEA parser or fix-validity check.
- The supplied project has no dedicated testbench, board pin constraints, or active timing constraints. Existing synthesis output concerns the FIFO IP and does not establish synthesis or timing closure of the complete top level.

Validation for this change checks preservation of non-comment HDL content and the original project/IP files. The integration points above have not been modified or verified on hardware.
