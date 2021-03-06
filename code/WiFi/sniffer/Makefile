# 
# Copyright (c) Microsoft Corporation
# All rights reserved. 
#
# Licensed under the Apache License, Version 2.0 (the ""License""); you
# may not use this file except in compliance with the License. You may
# obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
# LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
# A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#

# Disable default rules for C files
.SUFFIXES:

# Uncomment the following if you want winddk to be the default compiler. 
# NB: you can override this from the command line, e.g: 
# prompt> COMPILER=gcc make
#
COMPILER?=vs

PP    = ../../../scripts/preprocesscompile-$(COMPILER)-inline.sh
PPDEB = ../../../scripts/preprocesscompile-$(COMPILER)-debug.sh
DIFF  = ../../../tools/BlinkDiff
BLADERF_PATH_CYGW = $(shell cygpath -u '$(BLADERF_PATH)\x64')

# Do not delete outfiles to allow quick recheck of failed tests
# use make clean to get rid of them
.PRECIOUS: %.outfile %.out


# Targets
TGTS = $(patsubst %.blk, %.test, $(wildcard *.blk))

all: $(TGTS)


sniffer_test.out : sniffer_test.blk
	C_DEFINES='BLADE_RF' LIBS='bladeRF.lib' EXTRAOPTS='--bounds-check $(EXTRAOPTS)' $(PPDEB) $< $@

sniffer_example.out : sniffer_example.blk
	C_DEFINES='BLADE_RF' LIBS='bladeRF.lib' EXTRAOPTS='--bounds-check $(EXTRAOPTS)' $(PPDEB) $< $@

%.out : %.blk
	C_DEFINES='BLADE_RF' LIBS='bladeRF.lib' EXTRAOPTS='--vectorize --autolut $(EXTRAOPTS)' $(PP) $< $@


sniffer_test.outfile: sniffer_test.out ../matlab/pkt3.infile
	PATH="$(PATH)":"/cygdrive/c/Program Files/bladeRF/x64" \
	./$< --input=file \
             --input-file-name=../cts-to-self/cts-to-self_test.outfile \
             --input-file-mode=dbg \
             --output-file-name=$@ \
             --output-file-mode=dbg

%.test: %.outfile
	$(DIFF) -f $< -g $<.ground -d -v -n 0.9 -p

sniffer.run: sniffer.out
	PATH="$(PATH)":"/cygdrive/c/Program Files/bladeRF/x64" \
	./$< --input=sdr --heap-size=1000000000 --sdr-central-frequency=2412000000 --sdr-rx-gain=20 --input-file-mode=bin --output=dummy
#	./$< --input=sdr --sdr-central-frequency=2412000000 --sdr-rx-gain=20 --input-file-mode=bin --output=file --output-file-name=out.txt --output-file-mode=dbg --heap-size=1000000000 --output-buffer-size=30000000


sniffer_example.outfile: sniffer_example.out
	PATH="$(PATH)":"/cygdrive/c/Program Files/bladeRF/x64" \
	./$< --input=file --input-file-name=sniffer_example.infile --input-file-mode=dbg --output=dummy


%.accept : %.outfile
	cp $< $<.ground


clean:
	rm -f ./*expanded
	rm -f ./*exe ./*exec ./*out
	rm -f ./*.outfile
	rm -f ./compout ./perfout
	rm -f ./*.c

all-clean: clean
	rm -f ./*~
	rm -f ./*dump

