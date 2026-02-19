# vos-fastpath — SIP kernel-bypass (XDP + AF_XDP) for OpenSIPS
# CO-RE build; requires clang, libbpf, bpftool, kernel BTF

BPF_DIR   := bpf
OUT_DIR   := build
VMLINUX_H := $(OUT_DIR)/vmlinux.h
SIP_PROG  := $(OUT_DIR)/sip_logic.bpf.o

# Default NIC for vmlinux.h is from running system
KERNEL_BTF ?= /sys/kernel/btf/vmlinux

CLANG     ?= clang
LLVM_STRIP ?= llvm-strip
BPFTOOL   ?= $(shell command -v bpftool 2>/dev/null || echo /usr/sbin/bpftool)

# CO-RE flags for portability; libbpf headers (bpf_helpers.h, bpf_endian.h)
BPF_CFLAGS := -target bpf -O2 -mcpu=v3 \
	-I$(OUT_DIR) -I$(BPF_DIR) -I/usr/include \
	-D__TARGET_ARCH_$(shell uname -m | sed 's/x86_64/x86/;s/aarch64/arm64/') \
	-Wall -Wno-unused -Wno-pointer-sign

all: $(VMLINUX_H) $(SIP_PROG)

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

# Generate vmlinux.h from kernel BTF for CO-RE (requires bpftool, e.g. linux-tools-$(uname -r))
$(VMLINUX_H): $(OUT_DIR)
	@if [ ! -f "$(KERNEL_BTF)" ]; then \
		echo "ERROR: Kernel BTF not found at $(KERNEL_BTF). Need CONFIG_DEBUG_INFO_BTF=y."; \
		exit 1; \
	fi
	@if ! command -v "$(BPFTOOL)" >/dev/null 2>&1 && [ ! -x "$(BPFTOOL)" ]; then \
		echo "ERROR: bpftool not found. Install it (e.g. apt install linux-tools-$$(uname -r) or linux-tools-generic)."; \
		exit 1; \
	fi
	$(BPFTOOL) btf dump file $(KERNEL_BTF) format c > $@
	@echo "Generated $@"

$(SIP_PROG): $(BPF_DIR)/sip_logic.bpf.c $(VMLINUX_H)
	$(CLANG) $(BPF_CFLAGS) -g -c $(BPF_DIR)/sip_logic.bpf.c -o $@
	@echo "Built $@"

# Stress and correctness test (requires sudo, sim namespace)
test: $(SIP_PROG)
	@echo "Running stress test (sudo required, ~3 min)..."
	sudo bash $(CURDIR)/scripts/stress_test.sh 1

clean:
	rm -rf $(OUT_DIR)

.PHONY: all clean test
