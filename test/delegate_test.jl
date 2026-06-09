@testitem "@delegate" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    lb = LoggedBox()
    ds_store!(lb, 42)
    @test ds_fetch(lb) == 42
    @test satisfies(LoggedBox, DelegateStore).satisfied

    @test_throws Exception (@eval @delegate LoggedBox :inner UnregisteredDelegate)
end
