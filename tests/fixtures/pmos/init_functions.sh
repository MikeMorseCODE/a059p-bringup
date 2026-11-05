# Fixture: the parts of init_functions.sh the pipeline cares about.
# fail_halt_boot exists so the injection can be checked for producing a second
# definition that overrides this one.

run_hooks() {
	for hook in "$1"/*.sh; do
		[ -e "$hook" ] || continue
		sh "$hook"
	done
}

fail_halt_boot() {
	echo "Looping forever"
	while true; do
		sleep 1
	done
}
