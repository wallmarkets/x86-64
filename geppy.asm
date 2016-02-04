
; Distributed under GPL v1 License
; All Rights Reserved.



; This is main file that gets compiled.
;
;	     bios_boot.asm     executed first
; then	     kernel32.asm
; then	     kernel64.asm
; that's all



	format binary as 'img'
	org 0x8000
	use16


	include 'struct.inc'
	include 'const.inc'

macro reg val{
	pushd	  val
	call	  reg16
}

	include 'bios_boot.asm'

macro reg val, flags{
	pushf
	push	  eax
	mov	  eax, val
	pushd	  flags#h eax
	call	  reg32
	pop	  eax
	popf
}

	include 'kernel32.asm'

macro reg val, flags{
	pushfq
	push	  rax
	mov	  rax, val
	pushq	  flags#h rax
	call	  reg64
	pop	  rax
	popfq
}
macro ascii val, flags{
	pushf
	push	  eax
	mov	  eax, val
	pushd	  flags#h eax
	call	  ascii64
	pop	  eax
	popf
}

	align 16
_pmode_ends:

;===================================================================================================
;			 shared data
;===================================================================================================


; identity mapped (most used once and forgotten)

acpiLapicIDs	= 0x7e000	; 1KB = 256 CPUs * 4 bytes;  index = 4byte acpiID; value = lapicID
bootCpuInfo	= 0x7f000	; 4KB = 256 CPUs * 16 bytes; index = lapicID

; not identity mapped

acpiTbl = 0x80000	; at 512KB linear
fragMem = 0x1e4000	; 32KB
ioapic	= 0x1f0000	; 4 times 4KB
hpet	= 0x1f4000	; 4 times 4KB
lapic	= 0x1f8000	; 4KB
data1	= 0x1fc000
data2	= 0x1fd000
data3	= 0x1fe000
locks	= 0x1ff000
vbeLfb	= 0x2d000000	; at 720MB, 48MB in size
pcie	= 0x30000000	; at 768MB, 256MB in size

gdt		= data1
gdtr		= data1 + 64
time		= data1 + 80
largestLapicID	= data1 + 96
timeTicks	= data1 + 112

kCpuId2lapic	= data1 + 1024	; Map kernel CPU id to LapicID; Array index = kCpuId
				; 4bytes entries(contains LapicID) * 256 CPUs = 1KB
isaDevs 	= data1 + 2048
ioapic_gin	= data1 + 2368	; 4bytes vars; array index = ioapic index; value = ACPI GlobIntNumber
				;				  if value = -1, ioapic doesn't exist
ioapic_inputCnt = data1 + 2384	; 4bytes = 1byte (for each ioapic) * 4
				; if 0 - corresponding ioapic doesn't exist (after 'parse_MADT runs')
_?		= data1 + 2388

memPtr		= locks + 128
memTotal	= locks + 136
memLock 	= locks + 140




; 20byte device entry (for PCI & ISA busses)
;-----------------------------------
; +0   ISA PNP	 or    8byte dev+vendor id    (temporarily = 4byte acpi GlobIntNumber)
;
; +8   3byte class code (pci)
;
; +11  ioapic input 1byte
;
; +12  1byte:
;	  iopaic id 4bits	 [3:0]
;	  trigger bit		 [4]
;	  polarity trigger	 [5]
;	  undefined bit 	 [6]
;	  bit=1 if entry valid	 [7]
;
; +13	3byte offset to additional info in 8byte units
;
; +16	4byte pci bus/dev/func



;===================================================================================================
;			 per CPU private data
;===================================================================================================


idt		equ	r15

lapicT_stack	equ	r15+(4096+256)

; +0 RTC attached to CPU id, 1byte

;---------------------------------------------------------------------------------------------------
PF_stack	equ	r15+(4096+512)

PF_pages	equ	r15+((4096+512)-120)	; 8bytes
PF_2nd		equ	r15+((4096+512)-121)	; 1byte
PF_?		equ	r15+((4096+512)-122)	; 1byte
PF_r15		equ	r15+((4096+512)-128)	; 6bytes, value of R15 in 64KB units

sp_PF_pages	equ	rsp+8
sp_PF_2nd	equ	rsp+7
sp_PF_? 	equ	rsp+6
sp_PF_r15	equ	rsp

; PF_pages:
;---------------
; +0 bitmask 1byte, bit cleared - corresponding 4kb page mapped  (PF handler can only set bits)
; +1 last 4kb page that was used
; +2 cached size of the selected at +1 page
; +4 =0 if 4kb page with non-zeroed chunks, !=0 if 4kb with zeroed chunks
; +5 TODO: =1 if all pages (for which bit is set in "+0 bitmak") are unmapped
; +6 total mem mapped into PF_ram

;----------------------------------------
; the 4KB page that has 16KB RAM indexes
;----------------------------------------
; +0 size = number of 16kb indexes
; +4 =0 if 4kb page with non-zeroed chunks, !=0 if 4kb with zeroed chunks
; +8 8ytes undefined
;    pointer to next 16kb when pages are not mapped at PF_ram address (list terminated with 0 ptr)

;---------------------------------------------------------------------------------------------------

GP_stack	equ	r15+(4096+768)

DF_stack	equ	r15+(4096+1024)

HPET1_stack	equ	r15+(4096+1280)

interrupt_stack equ	r15+(4096+1408)

paging_ram	equ	r15+(8*1024)

;------------------- 1.0KB for frequently used data ------- same 4KB as some other data ------------

idtr		equ	r15+((15*1024)) 	; umm, never really used
pgRam4_size	equ	r15+((15*1024)+12)
_?		equ	r15+((15*1024)+16)

tss_data	equ	r15+(16*1024-2176)	; TSS is closer to threads, same 4KB (2176=2048+128)
threads 	equ	r15+(16*1024-2048)	; 16KB, initial threads inside same 4KB as other data
PF_ram		equ	r15+(32*1024)		; 32KB
pgRam4		equ	r15+(64*1024)		; 4KB


; 800 threads per 16KB
;------------------------------------------------------------------
;index in CPU private array = local to the CPU thread id
;------------------------------------------------------------------
;  +0 4byte phys addr of the control block
;  +4 4byte lin addr (for non position independed code)
;  +8 2byte globalThreadID
; +10 2byte next
; +12 2byte prev (for priority lists)
; +14 2byte time meant to run
; +16 4byte time left to run (positive - can still run, negative - ran too much)
;	     (can accumulate over time)

kStack		equ	r15+(128*1024)	; 64KB



;TODO: need to add checksum for the entire kernel (murmur)

; per cpu data located at different physical RAM  (includes PML4) and mapped to a unique linear addr
; to *completely* avoid TLB shootdown

; when one CPU updates mapping it sets flag in predefined location
; so that second CPU invalidates only when its ready

; get another bochs.exe that supports several local CPUs

;set error/sucess bit and display then as a hex number to indicate boot progress

;LAPIC ignores the trigger mode unless programmed as 'fixed'

;For all normal interrupts and IPIs
;(but not for NMI, SMI, INIT or spurious interrupts) you need to send an EOI to the local APIC

;----------------------------------------------------
;IOAPIC: 0=High active, 1=Low active.
;	 1=Level sensitive, 0=Edge sensitive
;----------------------------------------------------
; if
;     Conforms to the specifications of the bus
; then
;     edge triggered active high for ISA, level triggered active low for PCI,
;----------------------------------------------------
; ACPI
;Polarity
; 00 Conforms to specifications of the bus
;>01 Active high (ISA)
; 10 Reserved
; 11 Active low (PCI)
;
; ACPI
;Trigger Mode 2 2 Trigger mode of the APIC I/O Input signals:
; 00 Conforms to specifications of the bus
;>01 Edge-triggered (ISA)
; 10 Reserved
; 11 Level-triggered (PCI)

; need to force invlpg on all cpus that share same 4kb for mapping
; but can only do mandatory right-away invlpg when unmapping pages

; all free/alloc related to sys resources need to go into lowset priority thread

; can offer 2 mem pools, one withing low 47 bits, 2nd above 0xfff0'0000'0000'0000

;===================================================================================================


	include 'macros.inc'
	include 'kernel64.asm'

	include 'threads.asm'
	include 'acpi_apic.asm'
	include 'int_handlers.asm'
	include 'rtc_cmos.asm'
	include 'lapic_timer.asm'
	include 'memory.asm'
	include 'devices_ints.asm'
	include 'pci.asm'

	include 'bigDump/numbers.asm'

;===================================================================================================
;    read-only data for 64bit long mode
;===================================================================================================

LMode_data:

	include 'plug_and_play.inc'

_idt_exceptions_lmode:
	dw	int_DE-int_handlers, int_DB-int_handlers, int_NMI-int_handlers
	dw	int_BP-int_handlers, int_OF-int_handlers, int_BR-int_handlers
	dw	int_UD-int_handlers, int_NM-int_handlers, int_DF-int_handlers
	dw	int_dummy2-int_handlers, int_TS-int_handlers, int_NP-int_handlers
	dw	int_SS-int_handlers, int_GP-int_handlers, int_PF-int_handlers
	dw	int_dummy1-int_handlers, int_MF-int_handlers, int_AC-int_handlers
	dw	int_MC-int_handlers, int_XM-int_handlers, int_VE-int_handlers
  .cnt = ($-_idt_exceptions_lmode)/2

_lmode_ends:


;===================================================================================================
vbe_temp	= 0x1000	; 0:0x1000 address for ah=0x4f00

vars = 0			; accessed using GS segment (currently at 448KB = 0x7000_segment)
rmData = 448*1024

boot_disk	= vars + 0	; 1byte
max_pci_bus	= vars + 1	; 1b
___?		= vars + 2
acpi_mcfg	= vars + 4
acpi_dsdt	= vars + 8
acpi_facp	= vars + 12
acpi_rsdt	= vars + 16
acpi_apic	= vars + 20
acpi_facs	= vars + 24
acpi_hpet	= vars + 28
acpi_ssdt	= vars + 32	; 32 * 4bytes = 128b
acpi_ssdt_cnt	= vars + 160	; 16b
acpi_mcfg_len	= vars + 288
acpi_dsdt_len	= vars + 292
acpi_facp_len	= vars + 296
acpi_rsdt_len	= vars + 300
acpi_apic_len	= vars + 304
acpi_facs_len	= vars + 308
acpi_hpet_len	= vars + 312
acpi_ssdt_len	= vars + 316	; 16b
mp_table	= vars + 444
mp_table_len	= vars + 448

memMap_cnt2	= vars + 986	; 4bytes
tscBits 	= vars + 990	; 16bytes
ebda_mem	= vars + 1008
vbeCap		= vars + 1012	; capabilities field
vbeMem		= vars + 1016
vidModes_sel	= vars + 1020	; selected video mode
vidModes_cnt	= vars + 1021	; total video modes
memMap_szFailed = vars + 1022
memMap_cnt	= vars + 1023

vars_end	= vars + 1024

memMap		= vars + 1024	; max 64 entries, 16bytes each, =1KB, all entries must be 16b aligned
vidModes	= vars + 2048	; max 128 entries, 16bytes each, =2KB
vbe_temp2	= vars + 4096

dq 0x9198'7497'2048'2712