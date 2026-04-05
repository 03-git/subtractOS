---
aliases: fhir patient resource, parse fhir patient, read fhir patient, hl7 fhir patient, fhir demographics
tags: healthcare, fhir, hl7, api, parsing
verified: false
source: HL7 FHIR R4 Patient Resource Specification
---

PARSE A FHIR R4 PATIENT RESOURCE

Steps:
1. Confirm `resourceType` is "Patient". If not, you have the wrong resource.
2. Extract identifiers: `identifier[]` array. Each has `system` (namespace URI) and `value`. Common systems: MRN (facility-specific), SSN (urn:oid:2.16.840.1.113883.4.1), driver's license.
3. Extract name: `name[]` array. Find entry with `use: "official"`. Parse `family` (string), `given[]` (array -- first + middle), `prefix[]`, `suffix[]`.
4. Extract birth date: `birthDate` field (YYYY-MM-DD format).
5. Extract gender: `gender` field. Values: male, female, other, unknown.
6. Extract address: `address[]` array. Each has `line[]`, `city`, `state`, `postalCode`, `country`, `use` (home, work, temp).
7. Extract contact info: `telecom[]` array. Each has `system` (phone, email, fax), `value`, `use` (home, work, mobile).
8. Check extensions: `extension[]` array contains non-standard data. Common US Core extensions:
   - Race: url ending in `/us-core-race`
   - Ethnicity: url ending in `/us-core-ethnicity`
   - Birth sex: url ending in `/us-core-birthsex`

Notes:
- All arrays can be empty or absent. Always check for existence before accessing.
- `name` may have multiple entries (maiden name, nickname). Filter by `use` field.
- Dates may be partial: "2001" or "2001-06" are valid FHIR dates.
- FHIR servers may return `_revinclude` resources in a Bundle alongside the Patient. Parse the Bundle first, then extract the Patient entry.
