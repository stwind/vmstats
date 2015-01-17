.PHONY: all test clean edoc compile deps
REBAR=./rebar

export EXOMETER_PACKAGES="(minimal)"

all:
	@$(REBAR) get-deps compile

compile:
	@$(REBAR) compile

deps:
	@$(REBAR) get-deps

clean:
	@$(REBAR) clean

distclean:
	@$(REBAR) clean delete-deps

test:
	@$(REBAR) eunit skip_deps=true
