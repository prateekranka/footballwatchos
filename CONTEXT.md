# Football Performance

This context describes a personal football-performance system that records a player’s session on Apple Watch and analyzes it afterward on iPhone.

## Language

**Football Session**:
One recorded football outing from confirmed Start through confirmed Finish. The original recording remains intact even when the user applies an analysis trim afterward.
_Avoid_: Match, workout, game

**Venue**:
A reusable pitch area and orientation defined by the user. A Venue can improve spatial analysis but is never required to record a Football Session.
_Avoid_: Location, field, ground

**Observation**:
A value derived directly from recorded sensor evidence, such as heart rate, elapsed time, or distance. It does not infer an unobserved football action.
_Avoid_: Insight, prediction, Estimated Action

**Estimated Action**:
A probable pass, probable shot or powerful kick, or dribble/carry burst inferred from recorded evidence. It is always presented as estimated and includes a quality indicator.
_Avoid_: Event, confirmed action, stat

**Calibration Session**:
A deliberately labelled recording of representative football movements and non-action examples used to personalize Estimated Action detection.
_Avoid_: Training Session, test match

**Personal Baseline**:
The player’s own comparison reference, established after three Valid Sessions and subsequently calculated from the previous four Valid Sessions.
_Avoid_: Benchmark, norm, average player

**Valid Session**:
A Football Session whose required evidence satisfies the quality rules for baseline and trend calculations. A session can remain saved without being a Valid Session.
_Avoid_: Successful session, completed session
