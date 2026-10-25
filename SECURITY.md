# Security

## Reporting a vulnerability

Do not open a public issue for a security problem. Report it privately
through GitHub: [Report a vulnerability](https://github.com/hattoriai/cardbox/security/advisories/new).

Say what an attacker can do, and how: the write, the query or the event,
and the steps or the payload. We answer within a week, agree on a fix and
a date, and credit you in the advisory unless you ask us not to.

## Supported versions

Security fixes are made to the latest release. Cardbox is before 1.0, so a
fix is not backported to an earlier minor version.

## What is in scope

Cardbox takes values, queries and views from people, from the browser and
from agents, any of which can be crafted. A problem is in scope when such
input can:

- read or write a record of another collection than the one it names;
- run SQL of its own, or make a query fail on a value of another type;
- get past `allow?/3`, or write a value its field does not take;
- link a record to one of a collection its relation does not name.

Out of scope: which collections a person may read (your app scopes
them, as it scopes its own records), and what your `allow?/3` allows.
