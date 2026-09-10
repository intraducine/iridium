#include <stdint.h>
#include <assert.h>
void iridium_profile_enable(int);
void iridium_profile_record(uint64_t);
uint64_t iridium_profile_take_gap(void);
int main(void) {
    iridium_profile_enable(1);
    iridium_profile_record(100);
    assert(iridium_profile_take_gap() == 0);
    iridium_profile_record(110);
    iridium_profile_record(160);
    iridium_profile_record(170);
    assert(iridium_profile_take_gap() == 50);
    assert(iridium_profile_take_gap() == 0);
    iridium_profile_enable(0);
    assert(iridium_profile_take_gap() == 0);
}
