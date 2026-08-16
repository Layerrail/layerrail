# LayerRail hackathon pipeline

**Verified:** 2026-08-03  
**Scope:** Currently open, online competitions that accept an adult individual resident in Nigeria and do not require an incorporated company.  
**Method:** Official organizer pages and official Devpost rules only. Prize-pool totals are not expected winnings, and registration is not a submission.

## Registrations completed

Six registrations were confirmed by Devpost's **“Thanks for registering!”** page. They advertise a combined **$2,732,250** in prize pools, although each entry can win only the prizes allowed by that event's rules.

| Priority | Competition | Conservative deadline | Advertised pool / top cash prize | Required build | Cloud Steward concept | Status |
|---:|---|---|---|---|---|---|
| 1 | [Build with DataHub: The Agent Hackathon](https://datahub.devpost.com/) | 2026-08-10 17:00 ET / 22:00 WAT | $20,500 pool / $6,000 grand prize | A new application using open-source DataHub plus at least one of its MCP Server, Agent Context Kit, DataHub Skills, or Analytics Agent; public Apache-2.0 repository, working URL, and <3-minute video | Governed infrastructure context before approval-first planning | **Draft 4/5; live DataHub evidence missing** |
| 2 | [Arm Create: AI Optimization Challenge](https://arm-ai-optimization-challenge.devpost.com/) | 2026-08-14 16:00 PT / 2026-08-15 00:00 WAT | $8,000 pool / $3,000 overall prize | Create, migrate, or significantly improve an AI solution on Arm; public MIT or Apache-2.0 repository and reproducible Arm64 setup; video optional | Track 2 Cloud AI agent runtime and optimization evidence on Arm64 | **Draft 4/5; Arm AI optimization incomplete** |
| 3 | [Build with Gemini XPRIZE](https://xprize.devpost.com/) | 2026-08-17 13:00 PT / 21:00 WAT | $2,000,000 pool / $500,000 first prize | A new AI-operated business using at least one Google Cloud product and Gemini for any LLM functionality; repository, <3-minute video, product evidence, users, revenue, expenses, and related-party revenue disclosure | A small-business operator that turns plain-language intent into accountable plans | **Draft 3/5; GCP, users, and revenue evidence missing** |
| 4 | [CockroachDB × AWS: Build with Agentic Memory](https://cockroachdb-ai.devpost.com/) | 2026-08-18 17:00 ET / 22:00 WAT | $8,750 pool / $5,000 first prize | A new agentic application using CockroachDB as persistent memory, deployed on AWS, with at least two listed CockroachDB tools; public repository, functional demo, and <3-minute video | Durable plan, context, approval, and vector-recall memory | **Draft 3/5; second CockroachDB tool and AWS missing** |
| 5 | [CALL-E: Your Code Is Calling](https://call-e.devpost.com/) | **Treat 2026-09-14 04:45 WAT as the safe cutoff** | $10,000 pool / $4,000 practical-use prize | A new or significantly updated application using CALL-E SDK/API/MCP/CLI/SKILL; contribution PR to the official agents repository and <3-minute video | Consent-safe on-call incident notification that never approves infrastructure | **Draft 3/5; PR open, account/live call missing** |
| 6 | [RevenueCat Shipaton 2026](https://revenuecat-shipaton-2026.devpost.com/) | 2026-09-30 23:45 PDT / 2026-10-01 07:45 WAT | $685,000 pool / $100,000 grand prize | A first-public-release iOS, iPadOS, macOS, or Android app using RevenueCat purchases or ads; store listing, <2-minute video, icon, and screenshot | Optional mobile companion for alerts, approvals, and premium workflows | **Draft 3/5; eligible mobile/store release absent** |

### Deadline discrepancy

CALL-E's official-rules text displays **2026-09-14 11:45 SGT**, while the registered Devpost dashboard displays **2026-09-14 16:45 WAT**, equivalent to 23:45 SGT. Until the organizer resolves the conflict, use the earlier **04:45 WAT** cutoff implied by the rules text.

## One build, staged integrations

The shared project is **Cloud Steward**, a fresh standalone project begun on 2026-08-02:

- separate Apache-2.0 repository;
- no copied or relicensed LayerRail AGPL source;
- use LayerRail only through documented APIs or generated test fixtures;
- DataHub supplies infrastructure/data context;
- Gemini performs planning and explanation;
- CockroachDB stores durable agent memory;
- AWS is the required target for the CockroachDB entry but is not yet deployed;
- Arm64 supplies the optimized deployment target;
- CALL-E adds phone escalation after the August deadlines;
- an Android client with RevenueCat is optional and should be attempted only after the core entries are submitted.

This keeps the hackathon work genuinely new while extending LayerRail through a clean integration boundary. Every submission must disclose the shared base and explain the work added for that competition.

### Verified project evidence

- Public repository: <https://github.com/Layerrail/cloud-steward>
- Live disclosed demo: <https://cloud-steward.onrender.com>
- Public walkthrough: <https://youtu.be/tI2ZgGVbZcA>
- Devpost project: <https://devpost.com/software/cloud-steward>
- Green CI run: <https://github.com/Layerrail/cloud-steward/actions/runs/30781828308>
- CALL-E contribution: <https://github.com/CALLE-AI/awesome-phone-call-agents/pull/70>

CI verifies Python 3.12/3.13 tests, a native `aarch64` container build and benchmark, live Gemini structured output, and secure CockroachDB vector-memory integration. The public Render deployment still truthfully reports sample DataHub, deterministic planning, and local memory.

## Delivery sequence

1. **By August 9:** ship the DataHub version, public Apache-2.0 repository, deployment, tests, documentation, and video.
2. **By August 13:** add an Arm64 build, reproducible benchmark, memory/CPU measurements, and optimization notes.
3. **By August 16:** add Gemini/Google Cloud, user and cost evidence, and the XPRIZE business narrative.
4. **By August 17:** add CockroachDB persistent memory and deploy the integrated service on AWS.
5. **By September 12:** add a consent-safe CALL-E incident-escalation flow and contribution PR.
6. **By September 28:** decide whether an Android RevenueCat client has enough product value to justify store-review risk.

Do not wait for the final day: app-store approval, cloud-account verification, videos, public repositories, and judging access can all fail independently.

## Awaiting eligibility clarification

### Africa Deep Tech Challenge 2026

- [Official page](https://adtc-2026.devpost.com/) and [rules](https://adtc-2026.devpost.com/rules)
- Deadline: 2026-08-25 02:45 ET.
- Advertised cash: $16,500, plus finalist/semifinalist GPU support in the rules.
- Strong thematic fit: useful on-device LLMs on 8 GB commodity laptops for African users.
- Registration requires certifications that the project/company is under 12 months old and the product is not commercially live or showing active market traction.
- LayerRail itself cannot truthfully make the second certification because it is a live public beta with a 36-person cohort.
- A clarification email was sent to the official hackathon manager asking whether a new, separate, not-yet-launched individual project is eligible. **Do not register until the organizer answers.**

## Lower-priority or monitoring-only routes

| Route | Decision |
|---|---|
| [Global Hack Week: Agents](https://events.mlh.com/events/14312-global-hack-week-agents) | Online August 7–13 and technically relevant, but no cash prize is stated. MLH account creation is currently blocked by its anti-bot challenge; prioritize the six cash competitions first. |
| [NASA International Space Apps Challenge](https://www.spaceappschallenge.org/) | Monitor the official 2026 registration launch. It is valuable for open-data visibility but is not currently a verified cash route. |
| Agentic Cinema, YouCam, and Backblaze generative-media events | Do not divert the core team: their required media/retail use cases do not strengthen LayerRail's infrastructure wedge, and the Backblaze deadline is too close. |
| General Devpost student events | Exclude unless the founder independently confirms student eligibility; age alone is not evidence of enrollment. |
| Crypto/token hackathons | Exclude unless a genuine LayerRail product requirement emerges; do not manufacture blockchain usage for prize eligibility. |

## Critical rule constraints

- Register and submit as an **individual**, because LayerRail has no legal entity.
- Current registrations say **working solo**; do not add the cofounder without explicit participation confirmation.
- Marketing opt-ins were left unchecked where offered.
- DataHub requires an **Apache-2.0** repository. Arm requires **MIT or Apache-2.0**. The shared new repository should therefore use Apache-2.0.
- The live LayerRail AGPL repository cannot simply be relabeled for these events.
- DataHub, CockroachDB/AWS, and Gemini require new work created during their submission periods; Arm and CALL-E allow significant new updates. Starting the standalone project on 2026-08-02 is within all six periods.
- Prize verification may require identity, tax, banking, and eligibility documents. Registration does not bypass those checks.

## Primary sources

- [DataHub rules](https://datahub.devpost.com/rules)
- [CockroachDB × AWS rules](https://cockroachdb-ai.devpost.com/rules)
- [Gemini XPRIZE rules](https://xprize.devpost.com/rules)
- [Arm AI Optimization rules](https://arm-ai-optimization-challenge.devpost.com/rules)
- [CALL-E rules](https://call-e.devpost.com/rules)
- [RevenueCat Shipaton rules](https://revenuecat-shipaton-2026.devpost.com/rules)
- [Africa Deep Tech Challenge rules](https://adtc-2026.devpost.com/rules)
- [MLH Global Hack Week: Agents](https://events.mlh.com/events/14312-global-hack-week-agents)
- [NASA Space Apps](https://www.spaceappschallenge.org/)
