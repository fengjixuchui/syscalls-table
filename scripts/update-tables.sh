#!/bin/bash

KERNELSRC=$1
DATADIR=$PWD/data

if [ -z $KERNELSRC ]; then
	echo "give me path to Linux kernel sources:"
	echo ""
	echo "$0 path/to/Linux/kernel/sources"
	echo ""
	exit 1
fi

KVER=$(make -C ${KERNELSRC} kernelversion -s)
TEMP=$(mktemp -d)

grab_syscall_names_from_tables()
{
	# arm_sync_file_range is sync_file_range2() since 2.6.22
	# utimesat is PowerPC/SPU only
	# rest are not implemented
	#
	DEAD_SYSCALLS="afs_syscall|break|ftime|gtty|lock|mpx|oldwait4|prof|profil|putpmsg|security|stty|tuxcall|ulimit|vserver|arm_sync_file_range|utimesat|ni_syscall"
	FAKE_ENTRIES="^(available|reserved|unused|SYSCALL_MASK).*$"

	for tbl_file in $(find ${KERNELSRC}/arch -name syscall*.tbl)
	do
		grep -E -v "(^#|^$|sys_ni_syscall)" $tbl_file | awk '{ print $3 }' >> ${TEMP}/syscall-names.text
	done

	cat ${DATADIR}/syscall-names.text >>${TEMP}/syscall-names.text
	LC_ALL=C sort -u  ${TEMP}/syscall-names.text | grep -E -v $FAKE_ENTRIES | grep -E -v -w $DEAD_SYSCALLS >${DATADIR}/syscall-names.text
}

generate_list_syscalls_c()
{
	echo "
	#include <stdio.h>
	#include <asm/unistd.h>

	int main(void)
	{
	"

	for syscall in `cat data/syscall-names.text`
	do
		echo "
	#ifdef __NR_$syscall
		printf('$syscall\\t%d\\n', __NR_$syscall);
	#else
		printf('$syscall\\n');
	#endif
	"
	done

	echo " return 0;
	}
	"
}

export_headers()
{
	make -s -C ${KERNELSRC} ARCH=${arch} O=${PWD}/headers headers_install &>/dev/null
}

grab_syscall_names_from_unistd_h()
{
	grep -E -h "^#define __NR_" ${PWD}/headers/usr/include/asm/unistd*.h ${PWD}/headers/usr/include/asm-generic/unistd.h |
		grep -E -v "(unistd.h|NR3264|__NR_syscall|__SC_COMP|__NR_.*Linux|__NR_FAST)" |
		grep -E -vi "(not implemented|available|unused|reserved|xtensa|spill)" |
		grep -E -v "(__SYSCALL|SYSCALL_BASE|SYSCALL_MASK)" |
		sed -e "s/#define\s*__NR_//g" -e "s/\s.*//g" |
		grep -E -v -w $DEAD_SYSCALLS |
		sort -u >${TEMP}/syscall-names.text
	cat ${DATADIR}/syscall-names.text >>${TEMP}/syscall-names.text
	sed -i '/^arch_specific_syscall$/d' ${TEMP}/syscall-names.text
	LC_ALL=C sort -u ${TEMP}/syscall-names.text >${DATADIR}/syscall-names.text
}

generate_table() 
{
	echo -n "$arch "
	echo $arch >> ${DATADIR}/architectures-present-in-kernel.text

	if [ $bits == 32 ]; then
		extraflags="${extraflags} -D__BITS_PER_LONG=32"
	fi

	gcc list-syscalls.c -U__LP64__ -U__ILP32__ -U__i386__ -D${arch^^} \
		-D__${arch}__ ${extraflags} -I headers/usr/include/ -o list-syscalls &>/dev/null
	./list-syscalls > "${DATADIR}/tables/syscalls-$arch"
}

do_all_tables()
{
	cd $TEMP
	rm -f ${DATADIR}/architectures-present-in-kernel.text
	mkdir headers

	for archdir in $KERNELSRC/arch/*
	do 
		arch=`basename $archdir`

		bits=64
		extraflags=

		case ${arch} in
		Kconfig)
			continue;
			;;
		um)
			continue;
			;;
		esac

		export_headers
		grab_syscall_names_from_unistd_h

		case ${arch} in
		arm)
			bits=32
			arch=armoabi		extraflags=				generate_table
			arch=arm		extraflags=-D__ARM_EABI__		generate_table
			;;
		loongarch)
			# 32-bit variant of loongarch may appear
			arch=loongarch64	extraflags=-D_LOONGARCH_SZLONG=64	generate_table
			;;
		mips)
			arch=mips64		extraflags=-D_MIPS_SIM=_MIPS_SIM_ABI64	generate_table
			bits=32
			arch=mipso32		extraflags=-D_MIPS_SIM=_MIPS_SIM_ABI32	generate_table
			arch=mips64n32		extraflags=-D_MIPS_SIM=_MIPS_SIM_NABI32	generate_table
			;;
		powerpc)
											generate_table
			arch=powerpc64							generate_table
			;;
		riscv)
			arch=riscv64		extraflags=-D__LP64__			generate_table
			bits=32
			arch=riscv32		extraflags=-D__SIZEOF_POINTER__=4	generate_table
			;;
		s390)
			bits=32
											generate_table
			bits=64
			arch=s390x							generate_table
			;;
		sparc)
			bits=32
						extraflags=-D__32bit_syscall_numbers__	generate_table
			bits=64
			arch=sparc64		extraflags=-D__arch64__			generate_table
			;;
		tile)
											generate_table
			arch=tile64		extraflags="-D__LP64__ -D__tilegx__"	generate_table
			;;
		x86)
			arch=x86_64		extraflags=-D__LP64__			generate_table
			bits=32
			arch=i386							generate_table
			arch=x32		extraflags=-D__ILP32__			generate_table
			;;
		arc|csky|hexagon|m68k|microblaze|nios2|openrisc|sh|xtensa)
			bits=32 							generate_table
			;;
		*)
			generate_table
			;;
		esac
	done

	echo ""
}

touch data/syscall-names.text
grab_syscall_names_from_tables
generate_list_syscalls_c | sed -e "s/'/\"/g">${TEMP}/list-syscalls.c

do_all_tables

ls -l $TEMP/

rm -rf $TEMP
