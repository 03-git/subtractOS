---
aliases: submit 837p, edi healthcare claim, professional claim, hipaa claim submission, x12 837, billing claim
tags: healthcare, edi, x12, claims, hipaa
verified: false
source: X12 837P Implementation Guide, HIPAA Transaction Standards
---

CONSTRUCT AND SUBMIT AN 837P PROFESSIONAL CLAIM

Steps:
1. Assemble required data: provider NPI, patient demographics, insurance ID, diagnosis codes (ICD-10), procedure codes (CPT), dates of service, place of service code, charge amounts.
2. Build the EDI envelope:
   - ISA (interchange control header): sender/receiver IDs, date, control number.
   - GS (functional group header): transaction type 837, sender/receiver codes.
   - ST (transaction set header): transaction type 837, control number.
3. Build the claim hierarchy:
   - Loop 2000A: billing provider (NPI, taxonomy code, address).
   - Loop 2000B: subscriber (patient insurance ID, relationship to policyholder).
   - Loop 2000C: patient (if different from subscriber).
   - Loop 2300: claim-level data (claim ID, total charge, place of service, diagnosis codes via HI segment).
   - Loop 2400: service lines (CPT code, modifier, units, charge, date of service, diagnosis pointer).
4. Close the envelope: SE, GE, IEA trailers with matching control numbers.
5. Validate the file structure before submission. Control numbers must be unique. Segment terminators must be consistent.
6. Submit to clearinghouse (e.g., Office Ally, Availity, Trizetto) via SFTP, API, or web upload.
7. Monitor for 999 (acknowledgment) and 277CA (claim status) responses.

Notes:
- A 999 with AK9=R means the file was rejected for structural errors. Fix the EDI and resubmit.
- A 277CA with status 4 means the claim was denied. Check the reason code against X12 claim adjustment reason codes.
- NPI is 10 digits. Taxonomy code is 10 characters. ICD-10 codes do not include the decimal point in EDI.
- Test with the clearinghouse's sandbox before sending live claims. One bad ISA control number can reject the entire interchange.
