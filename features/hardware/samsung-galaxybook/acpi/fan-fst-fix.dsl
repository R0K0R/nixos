// ACPI fix: PNP0C0B FAN0._FST firmware bug on the Samsung Galaxy Book4
// Pro360 (NT960QGK, BIOS P14RHB.460.250425.04).
//
// The OEM's DSDT does `Local1 = FANT[Local0]` then `Local1 += 0x0A` --
// FANT[Local0] is a package-element Reference, not the Integer it looks
// like, so the addition throws AE_AML_OPERAND_TYPE and aborts _FST
// (kernel: "acpi-fan PNP0C0B:00: Error retrieving current fan status: -5").
// Wrapping the reference in DerefOf() is the whole fix.
//
// This is a brand-new SSDT (OEM ID/Table ID don't match anything the
// platform ships), so the kernel's initrd ACPI-table-upgrade mechanism
// appends it rather than replacing an existing table. Loaded after the
// DSDT, its Method(_FST) under the reopened FAN0 scope takes precedence
// over the OEM's broken one in the ACPI namespace.
//
// Rebuild after editing:
//   nix-shell -p acpica-tools --run "iasl patch-fan.dsl"
DefinitionBlock ("", "SSDT", 2, "GB4FIX", "FANFST", 0x00000001)
{
    External (_SB_.PC00.LPCB.FAN0, DeviceObj)
    External (_SB_.PC00.LPCB.FAN0.FANT, PkgObj)
    External (_SB_.PC00.LPCB.FAN0.SFST, PkgObj)
    External (_SB_.PC00.LPCB.H_EC, DeviceObj)
    External (_SB_.PC00.LPCB.H_EC.FANS, IntObj)

    Scope (_SB.PC00.LPCB.FAN0)
    {
        Method (_FST, 0, Serialized)  // _FST: Fan Status
        {
            Local0 = \_SB.PC00.LPCB.H_EC.FANS
            Switch (ToInteger (Local0))
            {
                Case (One)
                {
                    Local0 = One
                }
                Case (0x02)
                {
                    Local0 = 0x02
                }
                Case (0x03)
                {
                    Local0 = 0x03
                }
                Case (0x04)
                {
                    Local0 = 0x03
                }
                Case (0x05)
                {
                    Local0 = 0x04
                }
            }

            SFST [One] = Local0
            If ((Local0 == Zero))
            {
                SFST [0x02] = Local0
            }
            Else
            {
                Local0--
                Local1 = DerefOf (FANT [Local0])
                Local1 += 0x0A
                SFST [0x02] = Local1
            }

            Return (SFST)
        }
    }
}
