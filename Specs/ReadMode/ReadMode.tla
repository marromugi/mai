---------------------------- MODULE ReadMode ----------------------------
\* Who holds which copy of a writing's key, and when (#22, #24).
\*
\* The server holds the authoritative settings (mode, exclusions, revoked keys)
\* and the agent copies. Each device acts on its own last-synced view of those
\* settings and by its own clock, which may run behind the server's (a copy
\* made earlier and delivered late looks the same), so the server can be
\* handed a copy it must refuse.

EXTENDS Naturals, FiniteSets

CONSTANTS
    Devices,
    Writings,
    Agents,
    ForgedKey,     \* a public key nobody approved, posted in an agent's place
    NoKey,         \* the server holds no key for the agent
    MaxTime,
    MaxVersion,
    Broken         \* "none", or the name of one check left out on purpose

\* The public key each agent made for itself.
AgentKey(a) == <<"key", a>>

Keys == {AgentKey(a) : a \in Agents} \cup {ForgedKey}
Times == 0..MaxTime
Versions == 0..MaxVersion

Copy == [writing : Writings, version : Versions, agent : Agents,
         key : Keys, expires : Times]

Mode == [on : BOOLEAN, until : Times]
Off == [on |-> FALSE, until |-> 0]

Settings == [excluded : [Writings -> BOOLEAN], mode : Mode,
             revoked : SUBSET Keys]

VARIABLES
    now,        \* the server's clock
    clock,      \* [Devices -> Times]: each device's clock, never ahead of now
    version,    \* [Writings -> Versions]: each save makes a new writing key
    excluded,   \* [Writings -> BOOLEAN], as the server holds it
    mode,       \* the read mode, as the server holds it
    postedKey,  \* [Agents -> Keys \cup {NoKey}]: the public key the server hands out
    signed,     \* keys approved and signed on the iPhone
    revoked,    \* keys whose registration was taken back
    copies,     \* agent copies the server holds
    wrappedFor, \* every key a device ever wrapped a writing key for, accepted or not
    view        \* [Devices -> Settings]: each device's last-synced settings

vars == <<now, version, excluded, mode, postedKey, signed, revoked,
          copies, wrappedFor, view, clock>>

ServerSettings == [excluded |-> excluded, mode |-> mode, revoked |-> revoked]

-----------------------------------------------------------------------------
\* What device d checks, on its settings s, before wrapping a key for agent a.

KeyIsTrusted(s, a) ==
    LET k == postedKey[a] IN
    /\ k # NoKey
    /\ Broken = "SkipSignatureCheck" \/ k \in signed
    /\ k \notin s.revoked

DeviceWraps(d, s, w, a) ==
    /\ KeyIsTrusted(s, a)
    /\ ~s.excluded[w]
    /\ s.mode.on
    /\ clock[d] < s.mode.until

\* The copies device d on settings s sends for writing w at version v.
Wrap(d, s, w, v) ==
    {[writing |-> w, version |-> v, agent |-> a, key |-> postedKey[a],
      expires |-> s.mode.until] : a \in {b \in Agents : DeviceWraps(d, s, w, b)}}

\* What the server checks before keeping a copy, given the mode it will hold.
ServerAccepts(c, m, ver) ==
    /\ Broken = "AcceptExpired" \/ (m.on /\ now < m.until /\ c.expires = m.until)
    /\ Broken = "AcceptExcluded" \/ ~excluded[c.writing]
    /\ c.key = postedKey[c.agent]
    /\ Broken = "AcceptRevoked" \/ c.key \notin revoked
    /\ c.version = ver[c.writing]

-----------------------------------------------------------------------------
\* Device actions

\* Saving makes a new writing key; copies of the old version go.
Save(d, w) ==
    /\ version[w] < MaxVersion
    /\ LET ver == [version EXCEPT ![w] = @ + 1]
           out == Wrap(d, view[d], w, ver[w])
           kept == IF Broken = "KeepOldVersionCopy" THEN copies
                   ELSE {c \in copies : c.writing # w}
       IN /\ version' = ver
          /\ wrappedFor' = wrappedFor \cup {c.key : c \in out}
          /\ copies' = kept \cup {c \in out : ServerAccepts(c, mode, ver)}
    /\ UNCHANGED <<now, clock, excluded, mode, postedKey, signed, revoked, view>>

\* Turning on wraps every writing the device sees as not excluded.
\* Copies from an earlier period carry its expiry, so they go.
\* The server refuses a period that has already ended by its clock.
TurnOn(d, until) ==
    /\ ~view[d].mode.on
    /\ clock[d] < until
    /\ now < until
    /\ LET m == [on |-> TRUE, until |-> until]
           v2 == [view[d] EXCEPT !.mode = m]
           out == UNION {Wrap(d, v2, w, version[w]) : w \in Writings}
       IN /\ mode' = m
          /\ view' = [view EXCEPT ![d] = v2]
          /\ wrappedFor' = wrappedFor \cup {c.key : c \in out}
          /\ copies' = {c \in out : ServerAccepts(c, m, version)}
    /\ UNCHANGED <<now, clock, version, excluded, postedKey, signed, revoked>>

TurnOff(d) ==
    /\ mode' = Off
    /\ copies' = IF Broken = "KeepCopyOnTurnOff" THEN copies ELSE {}
    /\ view' = [view EXCEPT ![d].mode = Off]
    /\ UNCHANGED <<clock, now, version, excluded, postedKey, signed, revoked, wrappedFor>>

Exclude(d, w) ==
    /\ ~excluded[w]
    /\ excluded' = [excluded EXCEPT ![w] = TRUE]
    /\ copies' = IF Broken = "KeepCopyOnExclude" THEN copies
                 ELSE {c \in copies : c.writing # w}
    /\ view' = [view EXCEPT ![d].excluded[w] = TRUE]
    /\ UNCHANGED <<clock, now, version, mode, postedKey, signed, revoked, wrappedFor>>

\* Including a writing again makes no copy; its next save does.
Include(d, w) ==
    /\ excluded[w]
    /\ excluded' = [excluded EXCEPT ![w] = FALSE]
    /\ view' = [view EXCEPT ![d].excluded[w] = FALSE]
    /\ UNCHANGED <<clock, now, version, mode, postedKey, signed, revoked, copies, wrappedFor>>

Sync(d) ==
    /\ view[d] # ServerSettings
    /\ view' = [view EXCEPT ![d] = ServerSettings]
    /\ UNCHANGED <<clock, now, version, excluded, mode, postedKey, signed, revoked,
                   copies, wrappedFor>>

-----------------------------------------------------------------------------
\* Agent registration. Approval happens on the iPhone with the key read from
\* the agent itself (QR code or typed code), never with the server's copy.

PostKey(a) ==
    /\ postedKey' = [postedKey EXCEPT ![a] = AgentKey(a)]
    /\ UNCHANGED <<clock, now, version, excluded, mode, signed, revoked, copies, wrappedFor, view>>

\* Anyone who can reach the server can put another key in the agent's place.
PostForgedKey(a) ==
    /\ postedKey' = [postedKey EXCEPT ![a] = ForgedKey]
    /\ UNCHANGED <<clock, now, version, excluded, mode, signed, revoked, copies, wrappedFor, view>>

Approve(a) ==
    /\ AgentKey(a) \notin signed
    /\ AgentKey(a) \notin revoked
    /\ signed' = signed \cup {AgentKey(a)}
    /\ UNCHANGED <<clock, now, version, excluded, mode, postedKey, revoked, copies, wrappedFor, view>>

Revoke(d, a) ==
    /\ AgentKey(a) \in signed
    /\ AgentKey(a) \notin revoked
    /\ revoked' = revoked \cup {AgentKey(a)}
    /\ copies' = {c \in copies : c.key # AgentKey(a)}
    /\ view' = [view EXCEPT ![d].revoked = @ \cup {AgentKey(a)}]
    /\ UNCHANGED <<clock, now, version, excluded, mode, postedKey, signed, wrappedFor>>

-----------------------------------------------------------------------------
\* Time. The server drops expired copies before it answers anything later.

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ mode' = IF mode.on /\ mode.until <= now + 1 THEN Off ELSE mode
    /\ copies' = IF Broken = "KeepExpiredCopy" THEN copies
                 ELSE {c \in copies : now + 1 < c.expires}
    /\ UNCHANGED <<clock, version, excluded, postedKey, signed, revoked, wrappedFor, view>>

\* A device's clock catches up, up to the server's.
DeviceTick(d) ==
    /\ clock[d] < now
    /\ clock' = [clock EXCEPT ![d] = @ + 1]
    /\ UNCHANGED <<now, version, excluded, mode, postedKey, signed, revoked,
                   copies, wrappedFor, view>>

-----------------------------------------------------------------------------

Init ==
    /\ now = 0
    /\ version = [w \in Writings |-> 0]
    /\ excluded = [w \in Writings |-> FALSE]
    /\ mode = Off
    /\ postedKey = [a \in Agents |-> NoKey]
    /\ signed = {}
    /\ revoked = {}
    /\ copies = {}
    /\ clock = [d \in Devices |-> 0]
    /\ wrappedFor = {}
    /\ view = [d \in Devices |-> ServerSettings]

Next ==
    \/ \E d \in Devices, w \in Writings : Save(d, w) \/ Exclude(d, w) \/ Include(d, w)
    \/ \E d \in Devices, u \in Times : TurnOn(d, u)
    \/ \E d \in Devices : TurnOff(d) \/ Sync(d)
    \/ \E a \in Agents : PostKey(a) \/ PostForgedKey(a) \/ Approve(a)
    \/ \E d \in Devices, a \in Agents : Revoke(d, a)
    \/ \E d \in Devices : DeviceTick(d)
    \/ Tick

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Properties

TypeOK ==
    /\ now \in Times
    /\ version \in [Writings -> Versions]
    /\ excluded \in [Writings -> BOOLEAN]
    /\ mode \in Mode
    /\ postedKey \in [Agents -> Keys \cup {NoKey}]
    /\ signed \subseteq Keys
    /\ revoked \subseteq Keys
    /\ copies \subseteq Copy
    /\ clock \in [Devices -> Times]
    /\ wrappedFor \subseteq Keys
    /\ view \in [Devices -> Settings]

\* 除外した文書には、エージェントあての写しが存在しない。
NoCopyOfExcluded ==
    \A c \in copies : ~excluded[c.writing]

\* 期限が過ぎたら、写しは残っていない。
NoCopyPastExpiry ==
    \A c \in copies : now < c.expires

\* Copies exist only while the mode is on, and belong to its current period.
NoCopyOutsideMode ==
    \A c \in copies : mode.on /\ c.expires = mode.until

\* 署名のない公開鍵には、文書の鍵を包まない。
NeverWrapForUnsignedKey ==
    wrappedFor \subseteq signed

\* A revoked agent's key has no copy on the server.
NoCopyForRevokedKey ==
    \A c \in copies : c.key \notin revoked

\* The mode is on only before its expiry.
ModeEndsOnTime ==
    mode.on => now < mode.until

\* A device's clock never runs ahead of the server's.
ClockNeverAhead ==
    \A d \in Devices : clock[d] <= now

\* An agent's copy is of the writing's current version only.
CopyIsOfCurrentVersion ==
    \A c \in copies : c.version = version[c.writing]

=============================================================================
