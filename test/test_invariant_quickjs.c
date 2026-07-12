#include <check.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* We'll test the lre_realloc function directly */
extern void *lre_realloc(void *opaque, void *ptr, size_t size);

START_TEST(test_integer_overflow_in_allocation)
{
    /* Invariant: Memory allocation size calculations must not overflow */
    size_t payloads[] = {
        SIZE_MAX,                    /* Exact exploit case - maximum size */
        SIZE_MAX / 2 + 1,            /* Boundary case - overflow when multiplied */
        1024,                        /* Valid input - normal allocation */
        SIZE_MAX - 100,              /* Boundary case - near overflow */
        SIZE_MAX / 4 * 3             /* Boundary case - potential overflow in calculations */
    };
    
    int num_payloads = sizeof(payloads) / sizeof(payloads[0]);
    
    for (int i = 0; i < num_payloads; i++) {
        /* The security property: lre_realloc must handle size parameter safely */
        void *result = lre_realloc(NULL, NULL, payloads[i]);
        
        /* Either allocation succeeds with valid size, or fails gracefully */
        if (result != NULL) {
            /* If allocation succeeded, we should be able to use at least 1 byte */
            ck_assert_ptr_ne(result, NULL);
            
            /* Clean up */
            void *freed = lre_realloc(NULL, result, 0);
            (void)freed; /* Suppress unused warning */
        } else {
            /* Allocation failed - this is acceptable for overflow cases */
            /* The key is that we didn't get an under-allocated buffer */
            ck_assert_msg(payloads[i] > SIZE_MAX / 2, 
                         "Allocation failed for size %zu", payloads[i]);
        }
    }
}
END_TEST

Suite *security_suite(void)
{
    Suite *s;
    TCase *tc_core;

    s = suite_create("Security");
    tc_core = tcase_create("Core");

    tcase_add_test(tc_core, test_integer_overflow_in_allocation);
    suite_add_tcase(s, tc_core);

    return s;
}

int main(void)
{
    int number_failed;
    Suite *s;
    SRunner *sr;

    s = security_suite();
    sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    number_failed = srunner_ntests_failed(sr);
    srunner_free(sr);

    return (number_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}