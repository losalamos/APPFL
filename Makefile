build_dir := $(CURDIR)/build

all: codegen runtime

codegen: setup codegen_

runtime: setup runtime_

setup: FORCE
	@((test -d $(build_dir)) || (mkdir $(build_dir)))
	@((test -d $(build_dir)/bin) || (mkdir $(build_dir)/bin))
	@((test -d $(build_dir)/etc) || (mkdir $(build_dir)/etc))
	@(cp -f codegen/Prelude.stg $(build_dir)/etc/)

codegen_: FORCE
	@(cd codegen && cabal build)
	@(cp -f codegen/dist/build/stgc/stgc $(build_dir)/bin/)

runtime_: FORCE
	@(cd $(build_dir); cmake $(cmake_flags) ..)
	@(cd $(build_dir); make)

test: ctest tastytest

tastytest: FORCE 
	@(cd codegen && cabal test)

ctest: setup ctest_

ctest_: FORCE
	@(cd $(build_dir); cmake $(cmake_flags) ..)
	@(cd $(build_dir); ARGS="-D ExperimentalTest --no-compress-output" $(MAKE) test; cp Testing/`head -n 1 Testing/TAG`/Test.xml ./CTestResults.xml)

clean: FORCE
	@(cd codegen && cabal clean)
	@(cd test && rm -f *.stg.c 2>/dev/null)
	@(cd test/error && rm -f *.stg.c 2>/dev/null)
	@(rm -rf $(build_dir))

FORCE:
