package com.example.observability.search.architecture;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.importer.ClassFileImporter;
import org.junit.jupiter.api.Test;

class ArchitectureTest {
  @Test
  void controllersMustNotDependOnInfrastructure() {
    noClasses().that().resideInAPackage("..api..")
        .should().dependOnClassesThat().resideInAPackage("..infrastructure..")
        .check(new ClassFileImporter().importPackages("com.example.observability.search"));
  }
}
