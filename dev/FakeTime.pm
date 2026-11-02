package FakeTime;
# Makes RevBank's now() return $ENV{FAKE_TIME}, for generating a history.
BEGIN {
	*CORE::GLOBAL::time = sub () { $ENV{FAKE_TIME} // CORE::time };
	*CORE::GLOBAL::localtime = sub (;$) { CORE::localtime(@_ ? $_[0] : $ENV{FAKE_TIME} // CORE::time) };
}
1;
